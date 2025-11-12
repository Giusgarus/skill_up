import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../auth/data/services/auth_api.dart';
import '../../../auth/data/storage/auth_session_storage.dart';
import '../../data/profile_api.dart';
import '../../data/user_profile_info_storage.dart';
import '../../data/user_profile_storage.dart';
import '../../domain/user_profile_fields.dart';
import 'package:flutter_svg/flutter_svg.dart';

const double _formMaxWidth = 360; // larghezza compatta stile iniziale

/// Page displaying editable user information.
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
  AuthSession? _session;


  bool _isEditOpen = false;

  void _openEdit() {
    setState(() => _isEditOpen = true);
  }

  void _closeEdit() {
    FocusScope.of(context).unfocus();
    setState(() => _isEditOpen = false);
  }

  @override
  void initState() {
    super.initState();
    // controller per i campi definiti dal dominio
    for (final field in kUserProfileFields) {
      _controllers[field.id] = TextEditingController();
    }
    // ✅ controller per AGE (nuovo campo dropdown)
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

  Future<AuthSession?> _ensureSession() async {
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
      if (controller != null) controller.text = stored[field.id] ?? '';
    }
    // ✅ carica anche AGE se esiste
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
                content: Text('No active session found. Please log in again.')),
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

  Future<bool> _uploadProfileImage(File file, AuthSession session) async {
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
            content: Text(result.errorMessage ?? 'Failed to update $fieldId.'),
            duration: const Duration(milliseconds: 1500),
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
        child: Stack(
          children: [
            // 1) CONTENUTO ORIGINALE
            SafeArea(
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
                                                Colors.white),
                                          ),
                                        )
                                            : const Icon(Icons.photo_camera,
                                            size: 20, color: Colors.white),
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
                              readOnly: true, // 👈 aggiunto: impedisce la modifica
                            ),
                            const SizedBox(height: 16),

                            _PillInfoField(
                              label: 'Your name',
                              hint: 'name / nickname',
                              controller: _controllers['name']!,
                              onChanged: (v) => _onFieldChanged('name', v),
                            ),
                            const SizedBox(height: 16),

                            // === Age (nuovo dropdown) ===
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
                                  111, (i) => '${40 + i} kg'),
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

                            // ✅ PERSONALIZATION HUB BLOCCO
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
                                onTap: _openEdit,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
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
                                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          color: Colors.black,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                      const SizedBox(width: 14),
                                      SvgPicture.asset(
                                        'assets/icons/send_icon.svg',
                                        width: 24,
                                        height: 24,
                                        colorFilter: const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 40),
                            Center(
                              child: Text(
                                'That’s all for now!',
                                style:
                                Theme.of(context).textTheme.titleMedium?.copyWith(
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

            // 2) OVERLAY EDIT
            if (_isEditOpen)
              Positioned.fill(
                child: _EditOverlay(onClose: _closeEdit),
              ),
          ],
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

/// =======================
///  STILI PILL (usati SOLO per username/name e dropdown)
/// =======================
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
            fontSize: 16, fontWeight: FontWeight.w700, color: Colors.black);

// larghezza colonna etichetta (ritocca a piacere)
const double _labelWidth = 140;

/// === TEXT FIELD a pill (SOLO per username & name) — con etichetta a sinistra ===
class _PillInfoField extends StatelessWidget {
  const _PillInfoField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.onChanged,
    this.keyboardType,
    this.readOnly = false, // 👈 aggiunto
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
                color: readOnly ? Colors.grey[600] : Colors.black, // 👈 testo grigio se bloccato
              ),
              decoration: _pillDecoration(hint).copyWith(
                fillColor: readOnly ? Colors.grey[200] : Colors.white, // 👈 sfondo grigino
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// === DROPDOWN a pill — con etichetta a sinistra ===
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
              value: value,
              isExpanded: true,
              alignment: Alignment.center, // testo centrato nel box
              icon: const Icon(Icons.arrow_drop_down, color: Colors.black),
              style: _pillTextStyle(context),
              decoration: _pillDecoration(''),
              items: items
                  .map(
                    (e) => DropdownMenuItem<String>(
                  value: e,
                  alignment: Alignment.center, // centra nel menu
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

/// =======================
///  VECCHIO STILE (rettangolo r=22) per TUTTI GLI ALTRI CAMPI
/// =======================
class _InfoField extends StatelessWidget {
  const _InfoField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.onChanged,
    this.maxLines = 1,
    this.keyboardType,
  });

  final String label;
  final String hint;
  final int maxLines;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final labelStyle =
    Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: Colors.black,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Center(
          child: Text(label, style: labelStyle, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          onChanged: onChanged,
          maxLines: maxLines,
          keyboardType: keyboardType,
          textAlign: TextAlign.center,
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Color(0xAA9E9E9E)),
            filled: true,
            fillColor: Colors.white,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 18,
              vertical: maxLines > 1 ? 18 : 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: const BorderSide(color: Colors.white),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: const BorderSide(color: Colors.white),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(22),
              borderSide: BorderSide(
                color: Colors.white.withValues(alpha: 0.8),
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }
}


class _EditOverlay extends StatelessWidget {
  const _EditOverlay({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onClose, // tap fuori chiude
      child: Container(
        color: Colors.black.withOpacity(0.55), // scrim scuro
        child: Center(
          child: GestureDetector(
            onTap: () {}, // blocca il tap dentro il box
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(38),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 12,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              width: 360, // dimensione simile al popup "Add Habit"
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Edit Profile',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: Colors.black,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: onClose,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black,
                          ),
                          child: const Icon(Icons.close, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 18),

                  // corpo vuoto (placeholder)
                  Container(
                    height: 180,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.black.withOpacity(0.06)),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Popup empty for now',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Colors.black.withOpacity(0.6),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  // Pulsante SAVE (chiude per ora)
                  Align(
                    alignment: Alignment.center,
                    child: GestureDetector(
                      onTap: onClose,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(26),
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFF9A9E), Color(0xFFFFCF71)],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.15),
                              blurRadius: 10,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: Text(
                          'SAVE',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: Colors.white,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}