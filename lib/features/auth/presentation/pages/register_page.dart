import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../presentation/widgets/auth_scaffold.dart';
import '../../presentation/widgets/pill_text_field.dart';
import '../../../../shared/widgets/field_label.dart';
import '../../../../shared/widgets/round_arrow_button.dart';
import '../../data/services/auth_api.dart';
import '../../data/storage/auth_session_storage.dart';
import '../../utils/password_validator.dart';
import 'package:skill_up/features/home/presentation/pages/home_page.dart';

class RegisterPage extends StatefulWidget {
  static const route = '/register';
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _userC = TextEditingController();
  final _emailC = TextEditingController();
  final _pwdC = TextEditingController();
  final _authApi = AuthApi();
  final _sessionStorage = AuthSessionStorage();
  bool _loading = false;
  bool _obscurePassword = true;
  PasswordValidationResult _passwordStatus = evaluatePassword('');
  String? _usernameError;

  @override
  void initState() {
    super.initState();
    _pwdC.addListener(_onPasswordChanged);
  }

  @override
  void dispose() {
    _pwdC.removeListener(_onPasswordChanged);
    _userC.dispose();
    _emailC.dispose();
    _pwdC.dispose();
    _authApi.close();
    super.dispose();
  }

  void _onPasswordChanged() {
    final status = evaluatePassword(_pwdC.text);
    if (status == _passwordStatus) return;
    setState(() => _passwordStatus = status);
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Password required';
    final status = evaluatePassword(password);
    if (!status.isValid) return kPasswordRequirementsSummary;
    return null;
  }

  Future<void> _submit() async {
    setState(() => _usernameError = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final username = _userC.text.trim();
    final email = _emailC.text.trim();
    final password = _pwdC.text;

    try {
      final result = await _authApi.register(
        username: username,
        email: email,
        password: password,
      );

      if (!mounted) return;
      if (!result.isSuccess && kDebugMode && result.error != null) {
        debugPrint('Registration error: ${result.error}');
        if (result.stackTrace != null) {
          debugPrint(result.stackTrace.toString());
        }
      }

      final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();

      final successMessage = username.isEmpty
          ? 'Welcome!'
          : 'Welcome, $username!';
      final failureMessage =
          result.errorMessage ?? 'Registration failed. Please retry.';

      final isDuplicateUser =
          !result.isSuccess &&
          (result.errorMessage?.toLowerCase().contains('already') ?? false);

      if (isDuplicateUser) {
        setState(() => _usernameError = result.errorMessage);
      }

      if (result.isSuccess) {
        if (result.session != null) {
          try {
            await _sessionStorage.saveSession(result.session!);
          } catch (storageError, storageStackTrace) {
            if (kDebugMode) {
              debugPrint('Failed to persist session: $storageError');
              debugPrint(storageStackTrace.toString());
            }
          }
        }

        messenger.showSnackBar(SnackBar(content: Text(successMessage)));
      } else if (!isDuplicateUser) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(failureMessage),
            backgroundColor: Colors.redAccent,
          ),
        );
      }

      if (result.isSuccess) {
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, HomePage.route);
      }
    } catch (error, stackTrace) {
      if (!mounted) return;
      if (kDebugMode) {
        debugPrint('Registration request threw: $error');
        debugPrint(stackTrace.toString());
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Unexpected error. Please retry later.'),
            backgroundColor: Colors.redAccent,
          ),
        );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final passwordText = _pwdC.text;
    return AuthScaffold(
      title: 'Registration',
      form: Form(
        key: _formKey,
        child: Column(
          children: [
            const FieldLabel('Put your username:'),
            PillTextField(
              controller: _userC,
              hint: 'username',
              keyboardType: TextInputType.name,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Username required' : null,
            ),
            if (_usernameError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, left: 18),
                  child: Text(
                    _usernameError!,
                    style: TextStyle(
                      color: Colors.redAccent.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            const FieldLabel('Put your e-mail:'),
            PillTextField(
              controller: _emailC,
              hint: 'e-mail',
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                final value = v?.trim() ?? '';
                final regex = RegExp(r'^[\w\.\-]+@[\w\.\-]+\.[a-zA-Z]{2,}$');
                if (value.isEmpty) return 'E-mail required';
                if (!regex.hasMatch(value)) return 'Invalid e-mail';
                return null;
              },
            ),
            const SizedBox(height: 14),
            const FieldLabel('Put your password:'),
            PillTextField(
              controller: _pwdC,
              hint: 'password',
              obscureText: _obscurePassword,
              validator: _validatePassword,
              suffix: IconButton(
                tooltip: _obscurePassword ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            const SizedBox(height: 8),
            _PasswordRequirementsChecklist(
              status: _passwordStatus,
              shouldHighlightErrors: passwordText.isNotEmpty,
            ),
            const SizedBox(height: 22),
            RoundArrowButton(
              onPressed: _loading ? null : _submit,
              loading: _loading,
              svgAsset: 'assets/icons/send_icon.svg',
              iconSize: 32,
              tooltip: 'Accedi',
              // svgColor: Colors.black,
            ),
          ],
        ),
      ),
      footer: Wrap(
        alignment: WrapAlignment.center,
        children: [
          Text(
            "You have already an account? ",
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
            ),
          ),
          GestureDetector(
            onTap: () => Navigator.pushReplacementNamed(context, '/login'),
            child: const Text(
              "Login now",
              style: TextStyle(
                decoration: TextDecoration.underline,
                fontWeight: FontWeight.w800,
                color: Colors.black,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PasswordRequirementsChecklist extends StatelessWidget {
  const _PasswordRequirementsChecklist({
    required this.status,
    required this.shouldHighlightErrors,
  });

  final PasswordValidationResult status;
  final bool shouldHighlightErrors;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle =
        Theme.of(context).textTheme.bodySmall ?? const TextStyle(fontSize: 12);

    final requirements = <_PasswordRequirement>[
      _PasswordRequirement(
        label: 'At least $kMinPasswordLength characters',
        isMet: status.hasMinLength,
      ),
      _PasswordRequirement(
        label: 'Contains an uppercase letter',
        isMet: status.hasUppercase,
      ),
      _PasswordRequirement(
        label: 'Contains a lowercase letter',
        isMet: status.hasLowercase,
      ),
      _PasswordRequirement(label: 'Contains a digit', isMet: status.hasDigit),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: requirements.map((requirement) {
        final met = requirement.isMet;
        final Color color;
        if (met) {
          color = colorScheme.primary;
        } else if (shouldHighlightErrors) {
          color = colorScheme.error;
        } else {
          color = colorScheme.onSurface.withValues(alpha: 0.6);
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                met ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 16,
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  requirement.label,
                  style: baseStyle.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _PasswordRequirement {
  const _PasswordRequirement({required this.label, required this.isMet});

  final String label;
  final bool isMet;
}
