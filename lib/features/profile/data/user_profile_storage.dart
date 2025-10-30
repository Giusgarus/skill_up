import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Handles persisting and reading the user's profile picture locally.
class UserProfileStorage {
  UserProfileStorage._();

  static final UserProfileStorage instance = UserProfileStorage._();

  static const _profileImagePathKey = 'user_profile_image_path';

  String _keyFor(String username) => '$_profileImagePathKey::$username';

  String _sanitize(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    if (sanitized.isEmpty) {
      return 'user';
    }
    return sanitized;
  }

  /// Load the saved profile image file if present and still accessible.
  Future<File?> loadProfileImage(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final storedPath = prefs.getString(_keyFor(username));
    if (storedPath == null) {
      return null;
    }
    final file = File(storedPath);
    if (await file.exists()) {
      return file;
    }
    await prefs.remove(_keyFor(username));
    return null;
  }

  /// Persist the provided [image] to the app documents directory and return the
  /// stored file.
  Future<File> saveProfileImage(XFile image, {required String username}) async {
    final bytes = await image.readAsBytes();
    return saveProfileImageBytes(
      bytes,
      originalPath: image.path,
      username: username,
    );
  }

  /// Persist raw [bytes] as the profile image while attempting to keep the
  /// original file extension if provided.
  Future<File> saveProfileImageBytes(
    List<int> bytes, {
    String? originalPath,
    required String username,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final documents = await getApplicationDocumentsDirectory();
    final extension = originalPath != null ? p.extension(originalPath) : '.png';
    final fileName = 'profile_pic_${_sanitize(username)}$extension';
    final targetPath = p.join(documents.path, fileName);
    final existingPath = prefs.getString(_keyFor(username));
    if (existingPath != null && existingPath != targetPath) {
      final oldFile = File(existingPath);
      if (await oldFile.exists()) {
        await oldFile.delete();
      }
    }
    final file = File(targetPath);
    await file.writeAsBytes(bytes, flush: true);
    await prefs.setString(_keyFor(username), targetPath);
    return file;
  }

  /// Remove the stored profile picture reference.
  Future<void> clearProfileImage(String username) async {
    final prefs = await SharedPreferences.getInstance();
    final storedPath = prefs.getString(_keyFor(username));
    if (storedPath != null) {
      final file = File(storedPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    await prefs.remove(_keyFor(username));
  }

  /// Returns the stored file path, if any.
  Future<String?> loadImagePath(String username) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyFor(username));
  }
}
