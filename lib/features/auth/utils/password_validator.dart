/// Minimum password length enforced both client-side and server-side.
const int kMinPasswordLength = 8;

/// Human readable guidance explaining the password rules.
const String kPasswordRequirementsSummary =
    'Password must be at least $kMinPasswordLength characters long and '
    'include at least one uppercase letter, one lowercase letter, and one digit.';

/// Aggregates the rule checks so both UI and networking layers can share logic.
class PasswordValidationResult {
  const PasswordValidationResult({
    required this.hasMinLength,
    required this.hasUppercase,
    required this.hasLowercase,
    required this.hasDigit,
  });

  final bool hasMinLength;
  final bool hasUppercase;
  final bool hasLowercase;
  final bool hasDigit;

  bool get isValid => hasMinLength && hasUppercase && hasLowercase && hasDigit;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PasswordValidationResult &&
        hasMinLength == other.hasMinLength &&
        hasUppercase == other.hasUppercase &&
        hasLowercase == other.hasLowercase &&
        hasDigit == other.hasDigit;
  }

  @override
  int get hashCode =>
      Object.hash(hasMinLength, hasUppercase, hasLowercase, hasDigit);
}

/// Evaluate password strength based on the current backend requirements.
PasswordValidationResult evaluatePassword(String password) {
  final hasUppercase = RegExp(r'[A-Z]').hasMatch(password);
  final hasLowercase = RegExp(r'[a-z]').hasMatch(password);
  final hasDigit = RegExp(r'\d').hasMatch(password);

  return PasswordValidationResult(
    hasMinLength: password.length >= kMinPasswordLength,
    hasUppercase: hasUppercase,
    hasLowercase: hasLowercase,
    hasDigit: hasDigit,
  );
}

/// Convenience helper to quickly check if the password matches all rules.
bool isPasswordValid(String password) => evaluatePassword(password).isValid;
