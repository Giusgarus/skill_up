import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../presentation/widgets/auth_scaffold.dart';
import '../../presentation/widgets/pill_text_field.dart';
import '../../../../shared/widgets/field_label.dart';
import '../../../../shared/widgets/round_arrow_button.dart';
import '../../data/services/auth_api.dart';
import '../../data/storage/auth_session_storage.dart';
import '../../utils/password_validator.dart';
import '../../utils/notification_registration.dart';
import 'package:skill_up/features/home/presentation/pages/home_page.dart';
import 'package:skill_up/shared/widgets/likert_circle.dart';
import 'package:skill_up/features/profile/data/user_profile_info_storage.dart';
import 'package:skill_up/features/profile/data/profile_api.dart';
import 'package:skill_up/features/home/data/medal_history_repository.dart';
import 'package:skill_up/features/home/data/user_stats_repository.dart';
import '../../data/services/gathering_api.dart';

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
  final UserProfileInfoStorage _profileInfoStorage = UserProfileInfoStorage.instance;
  final ProfileApi _profileApi = ProfileApi();
  final GatheringApi _gatheringApi = GatheringApi();
  bool _loading = false;
  bool _obscurePassword = true;
  PasswordValidationResult _passwordStatus = evaluatePassword('');
  String? _usernameError;
  String? _emailError;

  /// interessi scelti
  Set<String> _selectedImprovementAreas = <String>{};

  /// risposte al questionario (indice domanda 1..10 -> 0..4)
  Map<int, int> _onboardingAnswers = <int, int>{};

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
    _profileApi.close();
    _gatheringApi.close();
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

  /// Handler del bottone con la freccia.
  /// 1) Valida il form
  /// 2) Apre il bottom-sheet multi-step (interests + notice + domande)
  /// 3) Se confermato, salva i dati in stato e lancia _submit()
  Future<void> _handleRegisterPressed() async {
    // azzero errori sui campi base
    setState(() {
      _usernameError = null;
      _emailError = null;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    final username = _userC.text.trim();
    final email = _emailC.text.trim();
    final password = _pwdC.text;

    // ===== STEP 1: ONBOARDING (interests + basic info + notice + domande) =====
    final onboardingResult = await showModalBottomSheet<_OnboardingResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      isDismissible: true, // può trascinare giù per chiudere
      enableDrag: true,
      builder: (_) => _InterestsBottomSheet(
        initialSelection: _selectedImprovementAreas,
      ),
    );

    if (!mounted) return;

    // se ha chiuso con swipe / tap fuori / back → NIENTE REGISTRAZIONE
    if (onboardingResult == null) {
      return;
    }

    // ===== STEP 2: REGISTRAZIONE VERA E PROPRIA =====
    setState(() => _loading = true);

    try {
      final result = await _authApi.register(
        username: username,
        email: email,
        password: password,
      );

      if (!mounted) return;

      final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();

      final successMessage =
      username.isEmpty ? 'Welcome!' : 'Welcome, $username!';
      final failureMessage =
          result.errorMessage ?? 'Registration failed. Please retry.';

      final statusCode = result.statusCode;
      final isDuplicateUsername =
          !result.isSuccess && statusCode != null && statusCode == 403;
      final isDuplicateEmail =
          !result.isSuccess && statusCode != null && statusCode == 404;

      // username / email già usati
      if (isDuplicateUsername || isDuplicateEmail) {
        setState(() {
          if (isDuplicateUsername) {
            _usernameError =
                result.errorMessage ?? 'User already exists. Please login.';
          }
          if (isDuplicateEmail) {
            _emailError =
                result.errorMessage ?? 'E-mail already in use. Try a new one.';
          }
        });

        messenger.showSnackBar(
          SnackBar(
            content: Text(failureMessage),
            backgroundColor: Colors.redAccent,
          ),
        );

        setState(() => _loading = false);
        return;
      }

      // altro errore generico
      if (!result.isSuccess) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(failureMessage),
            backgroundColor: Colors.redAccent,
          ),
        );
        setState(() => _loading = false);
        return;
      }

      // success: salvo sessione come prima
      if (result.session != null) {
        final session = result.session!;
        try {
          await _sessionStorage.saveSession(session);
          // reset local stats/medals for new user
          MedalHistoryRepository.instance.clearForUser(session.username);
          UserStatsRepository.instance.resetStats();
          MedalHistoryRepository.instance.setActiveUser(session.username);
        } catch (storageError, storageStackTrace) {
          if (kDebugMode) {
            debugPrint('Failed to persist session: $storageError');
            debugPrint(storageStackTrace.toString());
          }
        }
        unawaited(registerNotificationsForSession(session));
      }

      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
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
      setState(() => _loading = false);
      return;
    }

    // arrivato qui: REGISTRAZIONE OK
    setState(() {
      _loading = false;
      _selectedImprovementAreas = onboardingResult.interests;
      _onboardingAnswers = onboardingResult.answers;
    });

    if (kDebugMode) {
      debugPrint('Selected areas: $_selectedImprovementAreas');
      debugPrint('Onboarding answers: $_onboardingAnswers');
      debugPrint('Skipped questions: ${onboardingResult.skippedQuestions}');
      debugPrint('Age: ${onboardingResult.age}');
      debugPrint('Gender: ${onboardingResult.gender}');
      debugPrint('Weight: ${onboardingResult.weight}');
      debugPrint('Height: ${onboardingResult.height}');
    }

    await _submitOnboardingData(onboardingResult);

    // ===== STEP 3: SALVO LE INFO PROFILO (username, età, ecc.) =====
    try {
      final session = await _sessionStorage.readSession();
      if (session != null) {
        // username
        await _profileInfoStorage.setField(
          session.username,
          'username',
          session.username,
        );
        await _profileApi.updateField(
          token: session.token,
          field: 'username',
          value: session.username,
        );

        // age / gender / weight / height
        if (onboardingResult.age != null) {
          await _profileInfoStorage.setField(
            session.username,
            'age',
            onboardingResult.age!,
          );
          await _profileApi.updateField(
            token: session.token,
            field: 'age',
            value: onboardingResult.age!,
          );
        }

        if (onboardingResult.gender != null) {
          await _profileInfoStorage.setField(
            session.username,
            'gender',
            onboardingResult.gender!,
          );
          await _profileApi.updateField(
            token: session.token,
            field: 'gender',
            value: onboardingResult.gender!,
          );
        }

        if (onboardingResult.weight != null) {
          await _profileInfoStorage.setField(
            session.username,
            'weight',
            onboardingResult.weight!,
          );
          await _profileApi.updateField(
            token: session.token,
            field: 'weight',
            value: onboardingResult.weight!,
          );
        }

        if (onboardingResult.height != null) {
          await _profileInfoStorage.setField(
            session.username,
            'height',
            onboardingResult.height!,
          );
          await _profileApi.updateField(
            token: session.token,
            field: 'height',
            value: onboardingResult.height!,
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to persist onboarding data: $e');
      }
    }

    if (!mounted) return;
    Navigator.pushReplacementNamed(context, HomePage.route);
  }


  Future<void> _submitOnboardingData(_OnboardingResult onboardingResult) async {
    final session = await _sessionStorage.readSession();
    if (session == null) {
      return;
    }

    // interests
    if (onboardingResult.interests.isNotEmpty) {
      await _gatheringApi.sendInterests(
        token: session.token,
        interests: onboardingResult.interests.toList(),
      );
    }

    // questions (only if answered)
    if (!onboardingResult.skippedQuestions &&
        onboardingResult.answers.isNotEmpty) {
      const totalQuestions = 10;
      final answersList = List<int>.filled(totalQuestions, 0);
      onboardingResult.answers.forEach((index, value) {
        final zeroBased = index - 1;
        if (zeroBased >= 0 && zeroBased < totalQuestions) {
          answersList[zeroBased] = value;
        }
      });
      await _gatheringApi.sendQuestions(
        token: session.token,
        answers: answersList,
      );
      // persist onboarding answers locally and on profile backend
      final encoded = jsonEncode(
        onboardingResult.answers.map((key, value) => MapEntry(key.toString(), value)),
      );
      await _profileInfoStorage.setField(
        session.username,
        'onboarding_answers',
        encoded,
      );
      await _profileApi.updateField(
        token: session.token,
        field: 'onboarding_answers',
        value: encoded,
      );
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
                final regex =
                RegExp(r'^[\w.\-]+@[\w.\-]+\.[a-zA-Z]{2,}$');
                if (value.isEmpty) return 'E-mail required';
                if (!regex.hasMatch(value)) return 'Invalid e-mail';
                return null;
              },
            ),
            if (_emailError != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(top: 6, left: 18),
                  child: Text(
                    _emailError!,
                    style: TextStyle(
                      color: Colors.redAccent.withValues(alpha: 0.9),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 14),
            const FieldLabel('Put your password:'),
            PillTextField(
              controller: _pwdC,
              hint: 'password',
              obscureText: _obscurePassword,
              validator: _validatePassword,
              suffix: IconButton(
                tooltip:
                _obscurePassword ? 'Show password' : 'Hide password',
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off
                      : Icons.visibility,
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
              onPressed: _loading ? null : _handleRegisterPressed,
              loading: _loading,
              svgAsset: 'assets/icons/send_icon.svg',
              iconSize: 32,
              tooltip: 'Register',
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
        Theme.of(context).textTheme.bodySmall ??
            const TextStyle(fontSize: 12);

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
      _PasswordRequirement(
        label: 'Contains a digit',
        isMet: status.hasDigit,
      ),
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

/// ===============================================
///  MODELLO DI RITORNO DAL BOTTOM SHEET
/// ===============================================
class _OnboardingResult {
  const _OnboardingResult({
    required this.interests,
    required this.answers,
    required this.skippedQuestions,
    this.age,
    this.gender,
    this.weight,
    this.height,
  });

  final Set<String> interests;
  final Map<int, int> answers;
  final bool skippedQuestions;

  // 👇 nuovi campi per la basic info
  final String? age;
  final String? gender;
  final String? weight;
  final String? height;
}

/// =========================
///  BOTTOM SHEET MULTI-STEP
/// =========================

class _InterestsBottomSheet extends StatefulWidget {
  const _InterestsBottomSheet({required this.initialSelection});

  final Set<String> initialSelection;

  @override
  State<_InterestsBottomSheet> createState() => _InterestsBottomSheetState();
}

class _InterestsBottomSheetState extends State<_InterestsBottomSheet> {
  late Set<String> _selected;
  String? _errorText;

  // 0 = interests, 1 = notice, 2..11 = domande
  int _currentPage = 0;

  // ✅ inizializzati direttamente qui
  final PageController _pageController = PageController(initialPage: 0);

  String? _age;
  String? _gender;
  String? _weight;
  String? _height;


  final List<String> _areas = const [
    'Health',
    'Mindfulness',
    'Productivity',
    'Career',
    'Learning',
    'Financial',
    'Creativity',
    'Sociality',
    'Home',
    'Digital detox',
  ];

  final List<String> _questions = const [
    'I usually have a clear idea of how I want to spend my day.',
    'I dedicate time each week to physical activity or movement.',
    'I feel satisfied with how I manage my free time.',
    'I’m able to keep focus when I’m working on something important.',
    'When trying something new, I prefer to learn gradually rather than all at once.',
    'I regularly review my goals and adjust them if needed.',
    'I feel I have a good balance between work / study and rest.',
    'I find it easy to disconnect from social media when I need to.',
    'I’m happy with how I take care of my body and mind.',
    'I’m confident in my ability to stick to a new habit.',
  ];

  /// indice domanda 1..10 -> 0..4
  final Map<int, int> _answers = <int, int>{};


  @override
  void initState() {
    super.initState();
    _selected = {...widget.initialSelection};
    // ✅ niente più assegnazioni qui
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // ---------- interests step ----------

  void _toggleArea(String label) {
    setState(() {
      _errorText = null;

      if (_selected.contains(label)) {
        _selected.remove(label);
      } else {
        if (_selected.length >= 4) {
          _errorText = 'You can select up to 4 areas.';
          return;
        }
        _selected.add(label);
      }
    });
  }

  void _goFromInterestsToNotice() {
    if (_selected.isEmpty) {
      setState(() {
        _errorText = 'Please select at least one area.';
      });
      return;
    }

    setState(() {
      _errorText = null;
      _currentPage = 1;
    });

    // 👉 ora andiamo alla pagina BASIC INFO (index 1)
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  // ---------- notice step ----------

  void _skipFromNotice() {
    if (_selected.isEmpty) {
      setState(() {
        _errorText = 'Please select at least one area.';
      });
      _pageController.animateToPage(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
      return;
    }
    Navigator.of(context).pop(
      _OnboardingResult(
        interests: _selected,
        answers: const <int, int>{},
        skippedQuestions: true,
        age: _age,
        gender: _gender,
        weight: _weight,
        height: _height,
      ),
    );
  }

  void _nextFromNotice() {
    _pageController.animateToPage(
      3, // 0 interests, 1 basic, 2 notice, 3 = Q1
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  // ---------- questions step ----------

  void _selectAnswer(int questionIndex, int value) {
    setState(() {
      _answers[questionIndex] = value;
    });
  }

  void _goFromBasicInfoToNotice() {
    if (_age == null || _gender == null || _weight == null || _height == null) {
      setState(() {
        _errorText = 'Please fill all the fields.';
      });
      return;
    }

    setState(() {
      _errorText = null;
      _currentPage = 2;
    });

    _pageController.animateToPage(
      2,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _goNextQuestion(int questionIndex) {
    if (!_answers.containsKey(questionIndex)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Please select an option before continuing.'),
            duration: Duration(milliseconds: 1300),
          ),
        );
      return;
    }

    if (questionIndex < 10) {
      // pageIndex for question q+1 = (q+1) + 2
      final nextPage = (questionIndex + 1) + 2;
      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      // ultima domanda → chiudo e ritorno tutto
      Navigator.of(context).pop(
        _OnboardingResult(
          interests: _selected,
          answers: Map<int, int>.from(_answers),
          skippedQuestions: false,
          age: _age,
          gender: _gender,
          weight: _weight,
          height: _height,
        ),
      );
    }
  }


  // ---------- UI: BASIC INFO (age, gender, weight, height) ----------

  Widget _buildBasicInfoPage(TextTheme textTheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'WE NEED SOME',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        Text(
          'INFOS',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 22),

        // CARD con gradiente come nel vecchio design
        Container(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              _buildBasicDropdownRow(
                label: 'Your gender',
                value: _gender,
                items: const [
                  'Female',
                  'Male',
                  'Non-binary',
                  'Prefer not to say',
                ],
                onChanged: (v) => setState(() => _gender = v),
              ),
              const SizedBox(height: 14),
              _buildBasicDropdownRow(
                label: 'Your weight',
                value: _weight,
                items: List<String>.generate(
                  111,
                      (i) => '${40 + i} kg',
                ),
                onChanged: (v) => setState(() => _weight = v),
              ),
              const SizedBox(height: 14),
              _buildBasicDropdownRow(
                label: 'Your height',
                value: _height,
                items: [
                  for (int cm = 140; cm <= 210; cm++)
                    '${(cm / 100).toStringAsFixed(2)} m'
                ],
                onChanged: (v) => setState(() => _height = v),
              ),
              const SizedBox(height: 14),
              _buildBasicDropdownRow(
                label: 'Age',
                value: _age,
                items: [
                  for (int years = 10; years <= 100; years++) '$years',
                ],
                onChanged: (v) => setState(() => _age = v),
              ),
            ],
          ),
        ),

        const SizedBox(height: 90),

        // Bottone NEXT separato, come nel mock
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Align(
            alignment: Alignment.centerRight, // 👈 ALLINEATO A DESTRA
            child: GestureDetector(
              onTap: _goFromBasicInfoToNotice,
              child: Container(
                width: 230,
                height: 80,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.20),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Row(
                  children: [
                    Text(
                        'NEXT',
                        style: TextStyle(
                          fontFamily: 'FugazOne',
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: Colors.black,
                          fontStyle: FontStyle.italic,
                          letterSpacing: 1.2,
                        ),
                    ),
                    const Spacer(),
                    SvgPicture.asset(
                      'assets/icons/send_icon.svg',
                      width: 40,
                      height: 40,
                      colorFilter: const ColorFilter.mode(
                        Colors.black,
                        BlendMode.srcIn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        )
      ],
    );
  }

  Widget _buildBasicDropdownRow({
    required String label,
    required String? value,
    required List<String> items,
    required ValueChanged<String> onChanged,
  }) {
    final textTheme = Theme.of(context).textTheme;

    final labelStyle = textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: labelStyle,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 56,
            child: DropdownButtonFormField<String>(
              value: value,
              isExpanded: true,
              alignment: Alignment.center,
              decoration: _basicPillDecoration(),
              style: _basicPillTextStyle(context),
              icon: const Icon(Icons.arrow_drop_down, color: Colors.black),
              items: items
                  .map(
                    (e) => DropdownMenuItem<String>(
                  value: e,
                  alignment: Alignment.center,
                  child: Text(e, style: _basicPillTextStyle(context)),
                ),
              )
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return FractionallySizedBox(
      heightFactor: 0.82, // ~come prima: 0.82 dell’altezza schermo
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 16,
              offset: Offset(0, -6),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
        child: Column(
          children: [
            // handle
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 18),

            Expanded(
              child: PageView.builder(
                controller: _pageController,
                physics: _currentPage <= 2
                    ? const NeverScrollableScrollPhysics()
                    : const BouncingScrollPhysics(),
                onPageChanged: (index) {
                  setState(() {
                    _currentPage = index;
                    _errorText = null;
                  });
                },
                // 0=interests, 1=basic, 2=notice, 3..12 domande
                itemCount: 13,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _buildInterestsPage(textTheme);
                  } else if (index == 1) {
                    return _buildBasicInfoPage(textTheme);
                  } else if (index == 2) {
                    return _buildNoticePage(textTheme);
                  } else {
                    final questionIndex = index - 2; // 1..10
                    return _buildQuestionPage(textTheme, questionIndex);
                  }
                },
              ),
            ),

            if (_errorText != null) ...[
              const SizedBox(height: 12),
              Text(
                _errorText!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------- UI: interests ----------

  Widget _buildInterestsPage(TextTheme textTheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'WHAT DO YOU\nWANT TO IMPROVE:',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 37,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '(at least 1, max 4)',
          style: textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: Colors.black.withOpacity(0.7),
          ),
        ),
        const SizedBox(height: 22),
        LayoutBuilder(
          builder: (context, constraints) {
            final double itemWidth = (constraints.maxWidth - 18) / 2;
            return Wrap(
              spacing: 15,
              runSpacing: 15,
              children: _areas.map((label) {
                final bool isActive = _selected.contains(label);
                return SizedBox(
                  width: itemWidth,
                  height: 56,
                  child: _ImprovementChip(
                    label: label,
                    isActive: isActive,
                    onTap: () => _toggleArea(label),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 40),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: _goFromInterestsToNotice,
            child: Container(
              width: 230,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.20),
                    blurRadius: 10,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 45),
              child: Row(
                children: [
                  Text(
                    'NEXT',
                    style: const TextStyle(
                      fontFamily: 'FugazOne',
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      color: Colors.black,
                    ),
                  ),
                  const Spacer(),
                  SvgPicture.asset(
                    'assets/icons/send_icon.svg',
                    width: 40,
                    height: 40,
                    colorFilter: const ColorFilter.mode(
                      Colors.black,
                      BlendMode.srcIn,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------- UI: notice ----------

  Widget _buildNoticePage(TextTheme textTheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'IMPORTANT',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        Text(
          'NOTICE',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            'Before continuing, we recommend that you provide us with some information and answer a few questions so that we can learn more about you and create personalized challenges.\n\n'
                'It will only take few minutes!\n\n'
                'This is not mandatory, but we cannot guarantee an optimal experience with the application. In any case you can do this in another moment.',
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Colors.black,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onTap: _skipFromNotice,
                child: Container(
                  height: 68,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF6F6F), Color(0xFFFF9A9E)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.20),
                        blurRadius: 10,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'SKIP',
                    style: const TextStyle(
                      fontFamily: 'FugazOne',
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: GestureDetector(
                onTap: _nextFromNotice,
                child: Container(
                  height: 68,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.20),
                        blurRadius: 10,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  child: Row(
                    children: [
                      Text(
                        'NEXT',
                        style: const TextStyle(
                          fontFamily: 'FugazOne',
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          fontStyle: FontStyle.italic,
                          color: Colors.black,
                        ),
                      ),
                      const Spacer(),
                      SvgPicture.asset(
                        'assets/icons/send_icon.svg',
                        width: 36,
                        height: 36,
                        colorFilter: const ColorFilter.mode(
                          Colors.black,
                          BlendMode.srcIn,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- UI: single question ----------

  Widget _buildQuestionPage(TextTheme textTheme, int questionIndex) {
    // questionIndex: 1..10
    final String questionText = _questions[questionIndex - 1];
    final int? selected = _answers[questionIndex];
    final bool isLast = questionIndex == 10;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center, // 👈 centra verticalmente
      children: [
        Text(
          'MORE ABOUT',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        Text(
          'YOU',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'FugazOne',
            fontSize: 44,
            fontWeight: FontWeight.w900,
            fontStyle: FontStyle.italic,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            children: [
              Text(
                questionText,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.black,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: List.generate(5, (i) {
                  final bool isSelected = selected == i;
                  return LikertCircle(
                    filled: isSelected,
                    onTap: () => _selectAnswer(questionIndex, i),
                  );
                }),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Disagree',
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                    ),
                  ),
                  Text(
                    'Agree',
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24), // 👈 invece dello Spacer, stacca dal fondo
        Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 40), // 👈 aggiunge margine verso il centro
              child: Text(
                '$questionIndex/10',
                style: const TextStyle(
                  fontFamily: 'FugazOne',
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  fontStyle: FontStyle.italic,
                  color: Colors.black,
                ),
              ),
            ),
            const Spacer(),
            GestureDetector(
              onTap: () => _goNextQuestion(questionIndex),
              child: Container(
                height: 72,
                width: 220,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.20),
                      blurRadius: 10,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: Row(
                  children: [
                    Text(
                      isLast ? 'FINISH' : 'NEXT',
                      style: const TextStyle(
                        fontFamily: 'FugazOne',
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic,
                        color: Colors.black,
                      ),
                    ),
                    const Spacer(),
                    SvgPicture.asset(
                      'assets/icons/send_icon.svg',
                      width: 36,
                      height: 36,
                      colorFilter: const ColorFilter.mode(
                        Colors.black,
                        BlendMode.srcIn,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------- CHIP & CERCHIETTI ----------

class _ImprovementChip extends StatelessWidget {
  const _ImprovementChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    final gradient = isActive
        ? const LinearGradient(
      colors: [Color(0xFFFF9A9E), Color(0xFFFFCF91)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    )
        : const LinearGradient(
      colors: [Color(0xFFB3B3B3), Color(0xFFB3B3B3)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );

    final textColor =
    isActive ? Colors.black : Colors.black.withOpacity(0.85);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isActive ? 0.18 : 0.10),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}


InputDecoration _basicPillDecoration() => const InputDecoration(
  filled: true,
  fillColor: Colors.white,
  border: OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(28)),
    borderSide: BorderSide.none,
  ),
  contentPadding: EdgeInsets.symmetric(horizontal: 18, vertical: 14),
);

TextStyle _basicPillTextStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    ) ??
        const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Colors.black,
        );
