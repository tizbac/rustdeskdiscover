package main

import (
	"fmt"
	"net"
	"os"
	"strings"
	"time"
)

const (
	rendezvousPort = 21116
	broadcastPort  = rendezvousPort + 3 // 21119
)

// Ping message: RendezvousMessage { peer_discovery: PeerDiscovery { cmd: "ping" } }
// Pre-encoded protobuf bytes. Field 22 -> varint tag needs 2 bytes (0xb2 0x01).
var pingMsg = []byte{0xb2, 0x01, 0x06, 0x0a, 0x04, 0x70, 0x69, 0x6e, 0x67}

type Peer struct {
	ID       string
	Hostname string
	MAC      string
	Username string
	Platform string
	IP       string
}

func main() {
	peers := discover()

	if len(peers) == 0 {
		fmt.Println("No RustDesk clients found on the network.")
		return
	}

	fmt.Printf("Found %d RustDesk client(s):\n\n", len(peers))
	fmt.Printf("%-12s %-30s %-18s %-15s %s\n", "ID", "HOSTNAME", "MAC", "IP", "PLATFORM")
	fmt.Printf("%-12s %-30s %-18s %-15s %s\n", strings.Repeat("-", 12), strings.Repeat("-", 30), strings.Repeat("-", 18), strings.Repeat("-", 15), strings.Repeat("-", 10))

	for _, p := range peers {
		fmt.Printf("%-12s %-30s %-18s %-15s %s\n", p.ID, p.Hostname, p.MAC, p.IP, p.Platform)
	}
}

func discover() []Peer {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error getting interfaces: %v\n", err)
		os.Exit(1)
	}

	var broadcastAddrs []string
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP.IsLoopback() {
			continue
		}
		ip4 := ipNet.IP.To4()
		if ip4 == nil {
			continue
		}
		// Calculate broadcast address
		bcast := make(net.IP, 4)
		for i := 0; i < 4; i++ {
			bcast[i] = ip4[i] | ^ipNet.Mask[i]
		}
		broadcastAddrs = append(broadcastAddrs, bcast.String())
	}

	if len(broadcastAddrs) == 0 {
		fmt.Fprintln(os.Stderr, "No suitable network interfaces found.")
		os.Exit(1)
	}

	// Listen on an ephemeral UDP port for responses.
	// RustDesk unicasts the pong back to the source address/port of our ping.
	conn, err := net.ListenPacket("udp4", ":0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error creating UDP socket: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	// Enable deadline so we don't wait forever
	deadline := time.Now().Add(3 * time.Second)
	conn.SetDeadline(deadline)

	// Send ping to each broadcast address
	for _, bcast := range broadcastAddrs {
		addr := fmt.Sprintf("%s:%d", bcast, broadcastPort)
		udpAddr, err := net.ResolveUDPAddr("udp4", addr)
		if err != nil {
			continue
		}
		conn.WriteTo(pingMsg, udpAddr)
	}

	// Also try multicast group 224.0.0.251 if applicable (some networks)
	mcastAddr, err := net.ResolveUDPAddr("udp4", fmt.Sprintf("224.0.0.251:%d", broadcastPort))
	if err == nil {
		conn.WriteTo(pingMsg, mcastAddr)
	}

	// Collect responses
	byKey := make(map[string]*Peer)
	var peers []Peer

	buf := make([]byte, 4096)
	for {
		n, raddr, err := conn.ReadFrom(buf)
		if err != nil {
			break // timeout or error
		}

		srcIP := raddr.String()
		// Strip port from address
		if idx := strings.LastIndex(srcIP, ":"); idx != -1 {
			srcIP = srcIP[:idx]
		}

		peer, ok := parseResponse(buf[:n])
		if !ok {
			continue
		}

		peer.IP = srcIP
		if peer.ID == "" && peer.Hostname == "" {
			continue
		}

		// De-duplicate: prefer the first interface that carries this client's
		// MAC address (3049...), keep the IP that has a real MAC when available.
		key := peer.ID
		if key == "" {
			key = peer.MAC
		}
		if key == "" {
			key = srcIP
		}

		if existing, dup := byKey[key]; dup {
			if existing.IP == "0.0.0.0" || existing.MAC == "" && peer.MAC != "" {
				*existing = *peer
			}
			continue
		}

		p := *peer
		byKey[key] = &p
		peers = append(peers, p)
	}

	return peers
}

// parseResponse decodes a RendezvousMessage protobuf and extracts PeerDiscovery fields.
func parseResponse(data []byte) (*Peer, bool) {
	fields := decodeProtobuf(data)

	pdBytes, ok := fields[22]
	if !ok {
		return nil, false
	}

	pdFields := decodeProtobuf(pdBytes)

	cmd, _ := pdFields.getString(1)
	if cmd != "pong" {
		return nil, false
	}

	id, _ := pdFields.getString(3)
	hostname, _ := pdFields.getString(5)
	mac, _ := pdFields.getString(2)
	username, _ := pdFields.getString(4)
	platform, _ := pdFields.getString(6)

	return &Peer{
		ID:       id,
		Hostname: hostname,
		MAC:      mac,
		Username: username,
		Platform: platform,
	}, true
}

// Minimal protobuf decoder for proto3 wire format.
type protoFields map[int][]byte

func decodeProtobuf(data []byte) protoFields {
	fields := make(protoFields)
	pos := 0
	for pos < len(data) {
		if pos+2 > len(data) {
			break
		}

		// Decode varint for field tag
		tag, n := decodeVarint(data, pos)
		if n == 0 {
			break
		}
		pos += n

		fieldNum := int(tag >> 3)
		wireType := tag & 0x7

		switch wireType {
		case 0: // varint
			_, n := decodeVarint(data, pos)
			pos += n
		case 1: // 64-bit
			pos += 8
		case 2: // length-delimited
			length, n := decodeVarint(data, pos)
			if n == 0 {
				return fields
			}
			pos += n
			if pos+int(length) > len(data) {
				return fields
			}
			value := make([]byte, length)
			copy(value, data[pos:pos+int(length)])
			fields[fieldNum] = value
			pos += int(length)
		case 5: // 32-bit
			pos += 4
		default:
			return fields
		}
	}
	return fields
}

func (f protoFields) getString(fieldNum int) (string, bool) {
	val, ok := f[fieldNum]
	if !ok {
		return "", false
	}
	return string(val), true
}

func decodeVarint(data []byte, pos int) (uint64, int) {
	var result uint64
	var shift uint
	for i := pos; i < len(data) && i < pos+10; i++ {
		b := data[i]
		result |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return result, i - pos + 1
		}
		shift += 7
	}
	return 0, 0
}
