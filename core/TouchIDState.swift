import Foundation
import LocalAuthentication

/// Whether macOS is currently demanding the password before Touch ID works.
public enum TouchIDState {

    public static var requiresPassword: Bool {
        var error: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return false
        }
        return error?.code == LAError.biometryLockout.rawValue
    }
}
