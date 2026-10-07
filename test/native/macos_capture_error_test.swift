import Foundation
import ScreenCaptureKit

/// Static regression coverage: constructs errors only, without capture or TCC requests.
@main
struct CaptureErrorTests {
    static func main() {
        let denial = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        let denied = CaptureErrorReport(denial, source: "system")
        precondition(denied.code == "systemCapturePermissionDenied")
        precondition(denied.message.contains("完全退出"))
        precondition(denied.details["domain"] as? String == SCStreamErrorDomain)
        precondition(denied.details["nativeCode"] as? Int == -3801)

        let startFailure = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStartAudioCapture.rawValue)
        let failed = CaptureErrorReport(startFailure, source: "system")
        precondition(failed.code == "systemAudioStartFailed")
        precondition(!CaptureErrorReport.isSystemPermissionDenied(startFailure))
        precondition(!failed.message.contains("未允许"))

        // An unrelated framework reusing the same numeric code is not a TCC denial.
        let unrelated = NSError(domain: "AudioDeviceError", code: -3801)
        precondition(CaptureErrorReport(unrelated, source: "system").code == "capture")
        precondition(!CaptureErrorReport.isSystemPermissionDenied(unrelated))

        let microphone = CaptureErrorReport(CaptureFailure.permissionDenied, source: "microphone")
        precondition(microphone.code == "microphonePermissionDenied")
        precondition(microphone.message.contains("麦克风"))
        precondition(!CaptureErrorReport.isSystemPermissionDenied(CaptureFailure.permissionDenied))
        print("4 capture-error regression cases passed; no audio captured.")
    }
}
