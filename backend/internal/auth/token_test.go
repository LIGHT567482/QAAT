package auth

import (
	"testing"
	"time"
)

func TestTokenRoundTrip(t *testing.T) {
	const secret = "test-secret"
	tok, err := IssueToken(secret, "uid-1", RoleQAStaff, time.Hour)
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	claims, err := ParseToken(secret, tok)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}
	if claims.UserID != "uid-1" || claims.Role != RoleQAStaff {
		t.Errorf("claims = %+v", claims)
	}
	// Wrong secret must fail.
	if _, err := ParseToken("other", tok); err == nil {
		t.Error("expected signature validation failure with wrong secret")
	}
}

func TestExpiredTokenRejected(t *testing.T) {
	const secret = "test-secret"
	tok, err := IssueToken(secret, "uid-1", RoleStudent, -time.Minute)
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	if _, err := ParseToken(secret, tok); err == nil {
		t.Error("expected expired token to be rejected")
	}
}
