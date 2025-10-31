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

  @override
  void initState() {
    super.initState();
    for (final field in kUserProfileFields) {
      _controllers[field.id] = TextEditingController();
    }
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
    if (_session != null) {
      return _session;
    }
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
    if (!mounted) {
      return;
    }
    _cachedValues
      ..clear()
      ..addAll(stored);
    for (final field in kUserProfileFields) {
      final controller = _controllers[field.id];
      if (controller != null) {
        controller.text = stored[field.id] ?? '';
      }
    }
    setState(() {});
  }

  Future<void> _selectAndUploadImage() async {
    if (_isProcessing) {
      return;
    }
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
        maxWidth: 1024,
      );
      if (picked == null) {
        return;
      }

      setState(() => _isProcessing = true);

      final session = await _ensureSession();
      if (session == null) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('No active session found. Please log in again.')),
          );
        return;
      }

      final storedFile = await _profileStorage.saveProfileImage(
        picked,
        username: session.username,
      );
      final uploadOk = await _uploadProfileImage(storedFile, session);

      if (!mounted) {
        return;
      }

      setState(() => _profileImage = storedFile);
      if (uploadOk) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Profile picture updated.')),
          );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Unable to update profile picture.'),
          ),
        );
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
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
            content: Text(result.errorMessage ?? 'Error uploading profile picture.'),
          ),
        );
      return false;
    }
    return true;
  }

  void _onFieldChanged(String fieldId, String value) {
    if (_cachedValues[fieldId] == value) {
      return;
    }
    _debounceTimers[fieldId]?.cancel();
    _debounceTimers[fieldId] = Timer(const Duration(milliseconds: 600), () {
      _persistField(fieldId, value);
    });
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
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.of(context).maybePop(),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.2),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.7),
                            width: 2,
                          ),
                        ),
                        padding: const EdgeInsets.all(10),
                        child: Image.asset(
                          'assets/icons/back.png',
                          fit: BoxFit.contain,
                        ),
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
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withValues(alpha: 0.3),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.7),
                                      width: 4,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(16),
                                  child: DecoratedBox(
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                    ),
                                    child: ClipOval(
                                      child: _profileImage == null
                                          ? Padding(
                                              padding: const EdgeInsets.all(16),
                                              child: Image.asset(
                                                'assets/icons/profile_icon.png',
                                                fit: BoxFit.contain,
                                              ),
                                            )
                                          : Image.file(
                                              _profileImage!,
                                              fit: BoxFit.cover,
                                            ),
                                    ),
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
                                        color: Colors.white,
                                        width: 3,
                                      ),
                                    ),
                                    child: _isProcessing
                                        ? const Padding(
                                            padding: EdgeInsets.all(8),
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
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
                      Text(
                        'Change your profile pic',
                        style: emphasisStyle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 36),
                for (final field in kUserProfileFields) ...[
                  _InfoField(
                    label: field.label,
                    hint: field.hint,
                    controller: _controllers[field.id]!,
                    maxLines: field.maxLines,
                    keyboardType: field.keyboardType,
                    onChanged: (value) => _onFieldChanged(field.id, value),
                  ),
                  SizedBox(height: field.spacing),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
    final labelStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: Colors.black,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: labelStyle),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          onChanged: onChanged,
          maxLines: maxLines,
          keyboardType: keyboardType,
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
