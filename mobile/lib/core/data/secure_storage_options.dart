import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one Keychain policy every [FlutterSecureStorage] in this app uses.
///
/// Every call site passed `aOptions` and nothing else, which on iOS silently
/// took `IOSOptions.defaultOptions` — `KeychainAccessibility.unlocked` and
/// `synchronizable: false` (flutter_secure_storage 9.2.4,
/// options/ios_options.dart:5). Two things were wrong with that default here.
///
/// **`unlocked` cannot be read while the phone is locked.** Android's
/// EncryptedSharedPreferences can, and the app relies on it: the FCM
/// background isolate decrypts a message preview
/// (`MessagePreviewPort`) without the user unlocking anything. On iOS the
/// same work happens in a Notification Service Extension, which runs while
/// the device is locked. `first_unlock` is the weakest class that still
/// answers there — the item is unreadable between a reboot and the first
/// unlock, and readable after.
///
/// **`_this_device` is not optional.** THREAT-MODEL.md §"HKDF between two
/// X25519 keys that never leave their devices" is a promise about the private
/// key, and the plain `first_unlock` class travels in an encrypted iCloud
/// backup and restores onto a NEW phone. The `_this_device` variant sets
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which no backup carries.
/// `synchronizable` stays at its `false` default, which keeps the item out of
/// iCloud Keychain for the same reason. It is not restated in the constructor
/// only because `avoid_redundant_argument_values` rejects that and this repo
/// counts its analyzer suppressions; if the upstream default ever changes,
/// this constant must state it explicitly.
///
/// NOT addressed here, and still open: iOS Keychain items **survive app
/// deletion**, so "a reinstall wipes the key" — true on Android — is false on
/// iOS. That is a behaviour change to the unlink ceremony and a factual
/// correction owed to web/privacy-policy.html:233, not a storage option.
const kMilesKeychain = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
);
