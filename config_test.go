package httpmux

import (
	"testing"
)

func TestValidate_ServerMode(t *testing.T) {
	c := &Config{Mode: "server", Listen: ":443", Smux: SmuxConfig{Version: 2}}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid server config should pass: %v", err)
	}
}

func TestValidate_ServerMode_NoListen(t *testing.T) {
	c := &Config{Mode: "server", Listen: "", Smux: SmuxConfig{Version: 2}}
	if err := c.Validate(); err == nil {
		t.Fatal("server without listen should fail")
	}
}

func TestValidate_ClientMode(t *testing.T) {
	c := &Config{Mode: "client", ServerURL: "example.com:443", Smux: SmuxConfig{Version: 2}}
	if err := c.Validate(); err != nil {
		t.Fatalf("valid client config should pass: %v", err)
	}
}

func TestValidate_ClientMode_NoServer(t *testing.T) {
	c := &Config{Mode: "client", Smux: SmuxConfig{Version: 2}}
	if err := c.Validate(); err == nil {
		t.Fatal("client without server_url or paths should fail")
	}
}

func TestValidate_InvalidMode(t *testing.T) {
	c := &Config{Mode: "proxy"}
	if err := c.Validate(); err == nil {
		t.Fatal("invalid mode should fail")
	}
}

func TestValidate_InvalidTransport(t *testing.T) {
	c := &Config{Mode: "server", Listen: ":443", Transport: "quic", Smux: SmuxConfig{Version: 2}}
	if err := c.Validate(); err == nil {
		t.Fatal("invalid transport should fail")
	}
}

func TestValidate_InvalidSmuxVersion(t *testing.T) {
	c := &Config{Mode: "server", Listen: ":443", Smux: SmuxConfig{Version: 5}}
	if err := c.Validate(); err == nil {
		t.Fatal("invalid smux version should fail")
	}
}
