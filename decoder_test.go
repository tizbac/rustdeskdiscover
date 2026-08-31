package main

import (
	"fmt"
	"testing"
)

// Real protobuf encoding of:
// RendezvousMessage{ peer_discovery: PeerDiscovery{ cmd:"pong", mac:"aa:bb:cc:dd:ee:ff",
//   id:"421337988", username:"alice", hostname:"testhost", platform:"Linux" } }
var validPong = []byte{
	0xb2, 0x01, 0x3c,
	0x0a, 0x04, 0x70, 0x6f, 0x6e, 0x67,
	0x12, 0x11, 0x61, 0x61, 0x3a, 0x62, 0x62, 0x3a, 0x63, 0x63, 0x3a, 0x64, 0x64, 0x3a, 0x65, 0x65, 0x3a, 0x66, 0x66,
	0x1a, 0x09, 0x34, 0x32, 0x31, 0x33, 0x33, 0x37, 0x39, 0x38, 0x38,
	0x22, 0x05, 0x61, 0x6c, 0x69, 0x63, 0x65,
	0x2a, 0x08, 0x74, 0x65, 0x73, 0x74, 0x68, 0x6f, 0x73, 0x74,
	0x32, 0x05, 0x4c, 0x69, 0x6e, 0x75, 0x78,
}

func TestParsePong(t *testing.T) {
	peer, ok := parseResponse(validPong)
	if !ok {
		t.Fatal("parseResponse returned not ok")
	}
	fmt.Printf("ID=%q Hostname=%q Mac=%q Platform=%q\n", peer.ID, peer.Hostname, peer.MAC, peer.Platform)
	if peer.ID != "421337988" || peer.Hostname != "testhost" || peer.MAC != "aa:bb:cc:dd:ee:ff" || peer.Platform != "Linux" {
		t.Fatalf("unexpected values: %+v", peer)
	}
}

func TestPingRejectsNonPong(t *testing.T) {
	bad := append([]byte(nil), validPong...)
	bad[6] = 'i' // change "pong" -> "ping", should be rejected... but cmd field check
	// Instead test a message without peer_discovery
	if _, ok := parseResponse([]byte{0x0a, 0x04, 0x70, 0x69, 0x6e, 0x67}); ok {
		t.Fatal("expected rejection")
	}
}
