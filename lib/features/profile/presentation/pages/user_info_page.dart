// lib/features/profile/presentation/pages/user_info_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:image_picker/image_picker.dart';

import '../../../auth/data/storage/auth_session_storage.dart';
import '../../data/profile_api.dart';
import '../../data/user_profile_info_storage.dart';
import '../../data/user_profile_storage.dart';
import '../../domain/user_profile_fields.dart';

import 'package:skill_up/shared/widgets/questions_bottom_sheet.dart';

class UserInfoPage extends StatefulWidget {
  const UserInfoPage({super.key});

  static const route = '/user-info';

  @override
  State<UserInfoPage> createState() => _UserInfoPageState();
}

class _UserInfoPageState extends State<UserInfoPage> {
  final UserProfileStorage _profileStorage = UserProfileStorage.instance;
  final UserProfileInfoStorage _infoStorage = UserProfileInfoStorage.instance;
  final AuthSessionStorage _authStorage = AuthSessionStorage();
  final ProfileApi _profileApi = ProfileApi();
  final ImagePicker _picker = ImagePicker();

  final Map<String, TextEditingController> _controllers =
  <String, TextEditingController>{};
  final Map<String, Timer?> _debounceTimers = <String, Timer?>{};
  final Map<String, String> _cachedValues = <String, String>{};

  File? _profileImage;
  bool _isProcessing = false;

  // tipo dinamico: ha almeno .username e .token
  dynamic _session;

  @override
  void initState() {
    super.initState();

    // controller per i campi definiti dal dominio
    for (final field in kUserProfileFields) {
      _controllers[field.id] = TextEditingController();
    }
    // controller extra per AGE
    _controllers.putIfAbsent('age', () => TextEditingController());

    _initializeUserData();
  }

  @override
  void dispose() {
    for (final timer in _debounceTimers.values) {
      timer?.cancel();
    }
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _profileApi.close();
    super.dispose();
  }

  Future<void> _initializeUserData() async {
    await _ensureSession();
    await Future.wait([
      _loadProfileImage(),
      _loadProfileFields(),
    ]);
  }

  Future<dynamic> _ensureSession() async {
    if (_session != null) return _session;
    _session = await _authStorage.readSession();
    return _session;
  }

  Future<void> _loadProfileImage() async {
    final session = await _ensureSession();
    if (!mounted) return;

    if (session == null) {
      setState(() => _profileImage = null);
      return;
    }

    final file = await _profileStorage.loadProfileImage(session.username);
    if (!mounted) return;

    setState(() => _profileImage = file);
  }

  Future<void> _loadProfileFields() async {
    final session = await _ensureSession();
    if (session == null) {
      if (!mounted) return;
      for (final controller in _controllers.values) {
        controller.text = '';
      }
      _cachedValues.clear();
      setState(() {});
      return;
    }

    final stored = await _infoStorage.loadAllFields(session.username);
    if (!mounted) return;

    _cachedValues
      ..clear()
      ..addAll(stored);

    for (final field in kUserProfileFields) {
      final controller = _controllers[field.id];
      if (controller != null) {
        controller.text = stored[field.id] ?? '';
      }
    }

    // AGE se esiste
    _controllers['age']?.text = stored['age'] ?? '';

    setState(() {});
  }

  Future<void> _selectAndUploadImage() async {
    if (_isProcessing) return;

    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1024,
      );
      if (picked == null) return;

      setState(() => _isProcessing = true);

      final session = await _ensureSession();
      if (session == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('No active session found. Please log in again.'),
            ),
          );
        return;
      }

      final storedFile =
      await _profileStorage.saveProfileImage(picked, username: session.username);
      final uploadOk = await _uploadProfileImage(storedFile, session);

      if (!mounted) return;

      setState(() => _profileImage = storedFile);
      if (uploadOk) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Profile picture updated.')),
          );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Unable to update profile picture.')),
        );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<bool> _uploadProfileImage(File file, dynamic session) async {
    final bytes = await file.readAsBytes();
    final base64Image = base64Encode(bytes);

    final result = await _profileApi.uploadProfilePicture(
      token: session.token,
      base64Image: base64Image,
    );

    if (!result.isSuccess && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content:
            Text(result.errorMessage ?? 'Error uploading profile picture.'),
          ),
        );
      return false;
    }
    return true;
  }

  void _onFieldChanged(String fieldId, String value) {
    if (_cachedValues[fieldId] == value) return;

    _debounceTimers[fieldId]?.cancel();
    _debounceTimers[fieldId] =
        Timer(const Duration(milliseconds: 600), () => _persistField(fieldId, value));
  }

  Future<void> _persistField(String fieldId, String value) async {
    final session = await _ensureSession();
    if (session == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('No active session found. Please log in again.'),
            ),
          );
      }
      return;
    }

    try {
      await _infoStorage.setField(session.username, fieldId, value);
      _cachedValues[fieldId] = value;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('Could not save $fieldId locally.'),
              duration: const Duration(milliseconds: 1400),
            ),
          );
      }
    }

    final result = await _profileApi.updateField(
      token: session.token,
      field: fieldId,
      value: value,
    );

    if (!result.isSuccess && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content:
            Text(result.errorMessage ?? 'Failed to update $fieldId.'),
            duration: const Duration(milliseconds: 1500),
          ),
        );
    }
  }

  /// Apre il bottom sheet SOLO con le domande (senza notice, senza interests)
  Future<void> _openQuestionsEdit() async {
    final session = await _ensureSession();
    if (session == null) return;

    // 1) carico tutti i campi salvati localmente
    final stored = await _infoStorage.loadAllFields(session.username);

    // 2) provo a decodificare le risposte del questionario
    final String? raw = stored['onboarding_answers'];
    final Map<int, int> initialAnswers = <int, int>{};

    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        decoded.forEach((key, value) {
          final q = int.tryParse(key);
          final v = (value as num?)?.toInt();
          if (q != null && v != null) {
            initialAnswers[q] = v;
          }
        });
      } catch (_) {
        // se fallisce il parse, parto semplicemente vuoto
      }
    }

    if (!mounted) return;

    // 3) apro il bottom sheet SOLO domande, precompilato
    final updatedAnswers = await showModalBottomSheet<Map<int, int>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => QuestionsBottomSheet(
        initialAnswers: initialAnswers,
      ),
    );

    // se ha chiuso col back / swipe giù, non faccio nulla
    if (updatedAnswers == null) return;

    // 4) salvo in locale come JSON: { "1": 3, "2": 0, ... }
    final String encoded = jsonEncode(
      updatedAnswers.map((key, value) => MapEntry(key.toString(), value)),
    );

    await _infoStorage.setField(
      session.username,
      'onboarding_answers',
      encoded,
    );

    // 5) mando anche al backend come un normale campo profilo
    final result = await _profileApi.updateField(
      token: session.token,
      field: 'onboarding_answers',
      value: encoded,
    );

    if (!mounted) return;

    if (!result.isSuccess) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.errorMessage ?? 'Failed to update your preferences.',
            ),
            duration: const Duration(milliseconds: 1500),
          ),
        );
    } else {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Preferences updated.'),
            duration: Duration(milliseconds: 1300),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.displaySmall?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.white,
      letterSpacing: 1.1,
    );
    final emphasisStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      color: Colors.black,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFFF9A9E), Color(0xFFFAD0C4), Color(0xFFFFCF71)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // === Barra in alto con freccia e titolo ===
                Row(
                  children: [
                    Transform.translate(
                      offset: const Offset(-24, 0),
                      child: _SidePillBackButton(
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        'USER INFO',
                        style: titleStyle ??
                            const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 28),

                // === Immagine profilo + testo ===
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _isProcessing ? null : _selectAndUploadImage,
                          customBorder: const CircleBorder(),
                          child: SizedBox(
                            width: 116,
                            height: 116,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                ClipOval(
                                  child: _profileImage == null
                                      ? Center(
                                    child: Image.asset(
                                      'assets/icons/profile_icon.png',
                                      width: 96,
                                      height: 96,
                                      fit: BoxFit.contain,
                                      filterQuality: FilterQuality.high,
                                    ),
                                  )
                                      : Image.file(
                                    _profileImage!,
                                    width: double.infinity,
                                    height: double.infinity,
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.high,
                                  ),
                                ),
                                Positioned(
                                  right: -2,
                                  bottom: -2,
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: Colors.black,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                          color: Colors.white, width: 3),
                                    ),
                                    child: _isProcessing
                                        ? const Padding(
                                      padding: EdgeInsets.all(8),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                        AlwaysStoppedAnimation<Color>(
                                          Colors.white,
                                        ),
                                      ),
                                    )
                                        : const Icon(
                                      Icons.photo_camera,
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 18),
                      Text('Change your profile pic', style: emphasisStyle),
                    ],
                  ),
                ),

                const SizedBox(height: 36),

                // === Colonna compatta centrata ===
                Align(
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: 320,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PillInfoField(
                          label: 'Your username',
                          hint: 'username',
                          controller: _controllers['username']!,
                          onChanged: (_) {},
                          readOnly: true,
                        ),
                        const SizedBox(height: 16),

                        _PillInfoField(
                          label: 'Your name',
                          hint: 'name / nickname',
                          controller: _controllers['name']!,
                          onChanged: (v) => _onFieldChanged('name', v),
                        ),
                        const SizedBox(height: 16),

                        _LabeledDropdownPill(
                          label: 'Your age',
                          value: _controllers['age']?.text.isEmpty == true
                              ? null
                              : _controllers['age']!.text,
                          items: [
                            for (int years = 10; years <= 100; years++)
                              '$years years'
                          ],
                          onChanged: (v) {
                            _controllers['age']!.text = v;
                            _onFieldChanged('age', v);
                          },
                        ),
                        const SizedBox(height: 16),

                        _LabeledDropdownPill(
                          label: 'Your gender',
                          value: _controllers['gender']?.text.isEmpty == true
                              ? null
                              : _controllers['gender']!.text,
                          items: const [
                            'Female',
                            'Male',
                            'Non-binary',
                            'Prefer not to say'
                          ],
                          onChanged: (v) {
                            _controllers['gender']!.text = v;
                            _onFieldChanged('gender', v);
                          },
                        ),
                        const SizedBox(height: 16),

                        _LabeledDropdownPill(
                          label: 'Your weight',
                          value: _controllers['weight']?.text.isEmpty == true
                              ? null
                              : _controllers['weight']!.text,
                          items: List<String>.generate(
                            111,
                                (i) => '${40 + i} kg',
                          ),
                          onChanged: (v) {
                            _controllers['weight']!.text = v;
                            _onFieldChanged('weight', v);
                          },
                        ),
                        const SizedBox(height: 16),

                        _LabeledDropdownPill(
                          label: 'Your height',
                          value: _controllers['height']?.text.isEmpty == true
                              ? null
                              : _controllers['height']!.text,
                          items: [
                            for (int cm = 140; cm <= 210; cm++)
                              '${(cm / 100).toStringAsFixed(2)} m'
                          ],
                          onChanged: (v) {
                            _controllers['height']!.text = v;
                            _onFieldChanged('height', v);
                          },
                        ),
                        const SizedBox(height: 28),

                        // PERSONALIZATION HUB
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            'Personalization\nHub',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(
                              color: Colors.black,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: Image.asset(
                            'assets/icons/pers_hub.png',
                            width: 280,
                            fit: BoxFit.contain,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Center(
                          child: GestureDetector(
                            onTap: _openQuestionsEdit,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 40, vertical: 16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(40),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 6,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Text(
                                    'Edit',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                      color: Colors.black,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  SvgPicture.asset(
                                    'assets/icons/send_icon.svg',
                                    width: 24,
                                    height: 24,
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

                        const SizedBox(height: 34),

                        Center(
                          child: Text(
                            'All your current\nhabits with infos',
                            textAlign: TextAlign.center,
                            style: Theme.of(context)
                                .textTheme
                                .displaySmall
                                ?.copyWith(
                              fontWeight: FontWeight.w900,
                              color: Colors.black,
                            ),
                          ),
                        ),

                        const SizedBox(height: 26),

                        _HabitPlanButton(
                          title: 'DRINK MORE',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                const _HabitPlanPlaceholderPage(),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        _HabitPlanButton(
                          title: 'WALKING',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                const _HabitPlanPlaceholderPage(),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        _HabitPlanButton(
                          title: 'STUDYING',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                const _HabitPlanPlaceholderPage(),
                              ),
                            );
                          },
                        ),
                        const SizedBox(height: 18),
                        _HabitPlanButton(
                          title: 'EXERCISE',
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) =>
                                const _HabitPlanPlaceholderPage(),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 40),
                        Center(
                          child: Text(
                            'That’s all for now!',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: Colors.black.withOpacity(0.7),
                            ),
                          ),
                        ),
                        const SizedBox(height: 60),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidePillBackButton extends StatelessWidget {
  const _SidePillBackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFFB3B3B3),
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(28),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Image.asset(
          'assets/icons/back.png',
          width: 32,
          height: 32,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

// =======================
//  STILI PILL
// =======================

const double _pillHeight = 56;
const double _pillRadius = 28;

InputDecoration _pillDecoration(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(
    color: Color(0xAA9E9E9E),
    fontWeight: FontWeight.w600,
  ),
  filled: true,
  fillColor: Colors.white,
  contentPadding:
  const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(_pillRadius),
    borderSide: const BorderSide(color: Colors.white),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(_pillRadius),
    borderSide: const BorderSide(color: Colors.white),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(_pillRadius),
    borderSide: const BorderSide(color: Colors.white, width: 2),
  ),
);

TextStyle _pillTextStyle(BuildContext context) =>
    Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    ) ??
        const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: Colors.black,
        );

const double _labelWidth = 140;

class _PillInfoField extends StatelessWidget {
  const _PillInfoField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.onChanged,
    this.keyboardType,
    this.readOnly = false,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final labelStyle =
    Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: _labelWidth,
          child: Text(label, style: labelStyle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: _pillHeight,
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              keyboardType: keyboardType,
              readOnly: readOnly,
              textAlign: TextAlign.center,
              textAlignVertical: TextAlignVertical.center,
              style: _pillTextStyle(context).copyWith(
                color: readOnly ? Colors.grey[600] : Colors.black,
              ),
              decoration: _pillDecoration(hint).copyWith(
                fillColor: readOnly ? Colors.grey[200] : Colors.white,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LabeledDropdownPill extends StatelessWidget {
  const _LabeledDropdownPill({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final labelStyle =
    Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    final normalizedItems = <String>[];
    final seen = <String>{};
    for (final item in items) {
      if (seen.add(item)) {
        normalizedItems.add(item);
      }
    }

    String? normalizedValue = value;
    if (normalizedValue != null && !seen.contains(normalizedValue)) {
      normalizedItems.insert(0, normalizedValue);
      seen.add(normalizedValue);
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: _labelWidth,
          child: Text(label, style: labelStyle),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: _pillHeight,
            child: DropdownButtonFormField<String>(
              value: normalizedValue,
              isExpanded: true,
              alignment: Alignment.center,
              icon: const Icon(Icons.arrow_drop_down, color: Colors.black),
              style: _pillTextStyle(context),
              decoration: _pillDecoration(''),
              items: normalizedItems
                  .map(
                    (e) => DropdownMenuItem<String>(
                  value: e,
                  alignment: Alignment.center,
                  child: Text(e, style: _pillTextStyle(context)),
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
}

class _HabitPlanButton extends StatelessWidget {
  const _HabitPlanButton({
    required this.title,
    required this.onTap,
  });

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textStyle =
    Theme.of(context).textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w900,
      fontStyle: FontStyle.italic,
      letterSpacing: 1.2,
      color: Colors.black,
    );

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 96,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.10),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 26),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Center(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: textStyle,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.18),
                    blurRadius: 10,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              alignment: Alignment.center,
              child: SvgPicture.asset(
                'assets/icons/send_icon.svg',
                width: 34,
                height: 34,
                colorFilter: const ColorFilter.mode(
                  Colors.black,
                  BlendMode.srcIn,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HabitPlanPlaceholderPage extends StatelessWidget {
  const _HabitPlanPlaceholderPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Habit plan'),
      ),
      body: const Center(
        child: Text('Here we will show the habit details / plan.'),
      ),
    );
  }
}