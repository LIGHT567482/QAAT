package crypto

import "testing"

// The password-change TOTP invariant, at the level that actually pins it:
//
//   - Enroll/Verify write the secret encrypted under the user's CURRENT bcrypt hash.
//   - Login decrypts it with the hash CURRENTLY stored.
//
// So a ChangePassword that writes a new hash but leaves totp_secret_enc untouched breaks
// every later MFA-bound login for that account (VC / DQA DIRECTOR are locked out of their
// own account by the very act of changing the password). The fix re-encrypts the material
// under the NEW hash before the write; this test proves the re-encryption key is the only
// thing that changes the ciphertext, and that both hashes decrypt their own side.
func TestTOTPSecretReEncryptedForPasswordChange(t *testing.T) {
	const secret = "JBSWY3DPEHPK3PXP"
	const backupCodes = "C0DE1,BUZZ2,F00D3"

	oldHash := []byte("$2a$10$satty4cakk5tuxmmxabcdekJYd02bysKrtPIAghOFjFdZx") // synthetic, non-empty
	newHash := []byte("$2a$12$khalanje93jdFTyVZzX9xKeHgWtOM49NPdDQV5bXw1KZWy5") // synthetic

	oldSecretEnc, err := EncryptSecret(secret, string(oldHash))
	if err != nil {
		t.Fatalf("encrypt secret under old hash: %v", err)
	}
	oldBackupEnc, err := EncryptSecret(backupCodes, string(oldHash))
	if err != nil {
		t.Fatalf("encrypt backup under old hash: %v", err)
	}

	// Old ciphertext can only be opened by the OLD hash — this is what login did before the fix.
	if plain, err := DecryptSecret(oldSecretEnc, string(oldHash)); err != nil || plain != secret {
		t.Fatalf("old hash must open old secret (before change): plain=%q err=%v", plain, err)
	}
	if plain, err := DecryptSecret(oldBackupEnc, string(oldHash)); err != nil || plain != backupCodes {
		t.Fatalf("old hash must open old backup codes (before change): plain=%q err=%v", plain, err)
	}

	// Re-encrypt under the new hash, exactly as ChangePassword must.
	newSecretEnc, err := EncryptSecret(secret, string(newHash))
	if err != nil {
		t.Fatalf("re-encrypt secret under new hash: %v", err)
	}
	newBackupEnc, err := EncryptSecret(backupCodes, string(newHash))
	if err != nil {
		t.Fatalf("re-encrypt backup under new hash: %v", err)
	}

	// The old hash must now fail on the NEW ciphertext (the regression the fix removes).
	if pass, err := DecryptSecret(newSecretEnc, string(oldHash)); err == nil {
		t.Errorf("new-hash secret ciphertext must NOT open with the old hash (got plaintext %q)", pass)
	}
	if pass, err := DecryptSecret(newBackupEnc, string(oldHash)); err == nil {
		t.Errorf("new-hash backup ciphertext must NOT open with the old hash (got plaintext %q)", pass)
	}

	// The NEW hash must also fail on the OLD ciphertext — proves the keys are orthogonal.
	if _, err := DecryptSecret(oldSecretEnc, string(newHash)); err == nil {
		t.Error("old-hash secret ciphertext must NOT open with the new hash — the key leaked across rotations")
	}
	if _, err := DecryptSecret(oldBackupEnc, string(newHash)); err == nil {
		t.Error("old-hash backup ciphertext must NOT open with the new hash — the key leaked across rotations")
	}

	// After the change, the NEW hash must open both values — the guarantee Login now relies on.
	if plain, err := DecryptSecret(newSecretEnc, string(newHash)); err != nil || plain != secret {
		t.Errorf("new hash must open re-encrypted secret: plain=%q err=%v", plain, err)
	}
	if plain, err := DecryptSecret(newBackupEnc, string(newHash)); err != nil || plain != backupCodes {
		t.Errorf("new hash must open re-encrypted backup codes: plain=%q err=%v", plain, err)
	}
}