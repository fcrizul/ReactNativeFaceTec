import UIKit
import Foundation
import FaceTecSDK
import AVFoundation

class EnrollmentProcessor: NSObject, FaceTecFaceScanProcessorDelegate, URLSessionDelegate {
    /*, URLSessionDelegate, FaceTecFaceMapProcessorDelegate, FaceTecSessionDelegate*/ 
    /*var faceTecFaceMapResultCallback: FaceTecFaceMapResultCallback!
    var latestFaceTecSessionResult: FaceTecSessionResult?
    var latestFaceTecSessionMessage: String?
    var latestEnrollmentIdentidier: String!
    var latestJWTAccessToken: String!
    var isSuccess = false*/
    
    var maxRetries = -1
    var enrollmentIdentifier: String
    
    var isSuccess = false
    var lastMessage: String
    var lastResult: FaceTecSessionResult
    var resultCallback: FaceTecFaceScanResultCallback
    var retryAttempt = 0
    
    var delegate: ProcessingDelegate
    var presentSessionVCFrom: UIViewController
    
    private var alwaysRetry: Bool {
        get {
            return maxRetries == nil || maxRetries < 0
        }
    }

    init(fromVC: UIViewController, delegate: ProcessingDelegate) {
        self.delegate = delegate
        self.presentSessionVCFrom = fromVC

        super.init()
    }

    func enroll(_ enrollmentIdentifier: String, _ maxRetries: Int?) {
        requestCameraPermissions() {
            startSession() { sessionToken in
                let sessionVC = FaceTec.sdk.createSessionVC(faceScanProcessorDelegate: self, sessionToken: sessionToken)
                
                self.enrollmentIdentifier = enrollmentIdentifier
                self.maxRetries = maxRetries
                
                self.presentSessionVCFrom.present(sessionVC, animated: true, completion: {
                    EventEmitter.shared.dispatch(.UI_READY)
                })
            }
        }        
    }
    
    func processSessionWhileFaceTecSDKWaits(sessionResult: FaceTecSessionResult, faceScanResultCallback: FaceTecFaceScanResultCallback) {
        lastResult = sessionResult
        resultCallback = faceScanResultCallback
        
        if sessionResult.status != .sessionCompletedSuccessfully {
            FaceVerification.shared.cancelInFlightRequests()
            faceScanResultCallback.onFaceScanResultCancel()
            return
        }
        
        
        // notifying that capturing is done
        EventEmitter.shared.dispatch(.CAPTURE_DONE)

        // perform verification
        sendEnrollmentRequest()
    }
    
    func onFaceTecSDKCompletelyDone() {
        delegate.onProcessingComplete(isSuccess: isSuccess, sessionResult: lastResult, sessionMessage: lastMessage)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        // get progress while performing the upload
        let uploaded: Float = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
        
        if uploaded >= 1 {
            let processingMessage = Customization.resultFacescanProcessingMessage
            
            // switch status message to processing once upload completed
            resultCallback.onFaceScanUploadMessageOverride(uploadMessageOverride: processingMessage)
        }
        
        // updating the UX, upload progress from 10 to 80%
        resultCallback.onFaceScanUploadProgress(uploadedPercent: 0.1 + 0.7 * uploaded)
    }
    
    private func startSession(sessionTokenCallback: @escaping (String) -> Void) {
        FaceVerification.shared.getSessionToken() { sessionToken, error in
            if error != nil {
                self.delegate.onSessionTokenError()
                return
            }

            sessionTokenCallback(sessionToken!)
        }
    }
    
    private func requestCameraPermissions(requestCallback: @escaping () -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestCallback()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { (granted) in
                if (granted) {
                    requestCallback()
                } else {
                    self.delegate.onCameraAccessError()
                }
            }

        case .denied,
             .restricted:
            delegate.onCameraAccessError()
        }
    }
    
    private func sendEnrollmentRequest() -> Void {
        // setting initial progress to 0 for freeze progress bar
        resultCallback.onFaceScanUploadProgress(uploadedPercent: 0)
        
        var payload: [String : Any] = [
            "faceScan": lastResult.faceScanBase64,
            "auditTrailImage": lastResult.auditTrailCompressedBase64?.first!,
            "lowQualityAuditTrailImage": lastResult.lowQualityAuditTrailCompressedBase64?.first!,
            "externalDatabaseRefID": enrollmentIdentifier,
            "sessionId": lastResult.sessionId
        ]
        
        FaceVerification.shared.enroll(
            enrollmentIdentifier,
            payload,
            withDelegate: self
        ) { response, error in
            resultCallback.onFaceScanUploadProgress(uploadedPercent: 1)
            
            if error != nil {
                self.handleEnrollmentError(error!, response)
                return
            }
            
            isSuccess = true
            lastMessage = Customization.resultSuccessMessage
            
            FaceTecCustomization.setOverrideResultScreenSuccessMessage(lastMessage)
            resultCallback.onFaceScanResultSucceed()
        }
    }
    
    private func handleEnrollmentError(_ error: Error, _ response: [String: AnyObject]?) -> Void {
        let faceTecError = (error as? FaceVerificationError) ?? .unexpectedResponse
        
        // by default we'll use exception's message as lastMessage
        lastMessage = faceTecError.message
        
        if response != nil {
            let errorMessage: String? = response["error"]
            let enrollmentResult = response["enrollmentResult"]
            
            // if isDuplicate is strictly true, that means we have dup face
            let isDuplicateIssue = true == enrollmentResult?["isDuplicate"]
            let is3DMatchIssue = true == enrollmentResult?["isNotMatch"]
            let isLivenessIssue = false == enrollmentResult?["isLive"]
            let isEnrolled = true == enrollmentResult?["isEnrolled"]
            
            if errorMessage != nil {
                // setting lastMessage from server's response if was sent
                lastMessage = errorMessage
            }
            
            // if there's no duplicate / 3d match issues but we have
            // liveness issue strictly - we'll check for possible session retry
            if !isDuplicateIssue && !is3DMatchIssue && isLivenessIssue {
                // if haven't reached retries threshold or max retries is disabled
                // (is null or < 0) we'll ask to retry capturing
                if alwaysRetry || retryAttempt < maxRetries {
                    // increasing retry attempts counter
                    retryAttempt += 1
                    // showing reason
                    resultCallback.onFaceScanUploadMessageOverride(uploadMessageOverride: lastMessage)
                    // notifying about retry
                    resultCallback.onFaceScanResultRetry()
                    
                    // dispatching retry event
                    EventEmitter.shared.dispatch(.FV_RETRY, [
                        "reason": lastMessage,
                        "match3d": !is3DMatchIssue,
                        "liveness": !isLivenessIssue,
                        "duplicate": isDuplicateIssue,
                        "enrolled": isEnrolled
                    ])
                    
                    return
                }
            }
        }
        
        resultCallback.onFaceScanResultCancel()
    }
}