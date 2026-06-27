package main

import (
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"time"

	"google.golang.org/protobuf/proto"

	panelpb "hermes/proto/gen/panelpb/proto"
)

func main() {
	addr := "127.0.0.1:63446"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		panic(err)
	}
	defer conn.Close()

	args, _ := proto.Marshal(&panelpb.StartSessionArgs{SystemPrompt: "hi"})
	frame, _ := proto.Marshal(&panelpb.PanelFrame{Payload: &panelpb.PanelFrame_Request{Request: &panelpb.PanelRequest{
		Id: 1, Method: "start_session", ArgsBytes: args,
	}}})
	pkt := make([]byte, 4+len(frame))
	binary.BigEndian.PutUint32(pkt[:4], uint32(len(frame)))
	copy(pkt[4:], frame)
	fmt.Printf("sending %d bytes to %s\n", len(pkt), addr)
	if _, err := conn.Write(pkt); err != nil {
		panic(err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	hdr := make([]byte, 4)
	if _, err := conn.Read(hdr); err != nil {
		panic(err)
	}
	n := binary.BigEndian.Uint32(hdr)
	body := make([]byte, n)
	if _, err := conn.Read(body); err != nil {
		panic(err)
	}
	var resp panelpb.PanelFrame
	if err := proto.Unmarshal(body, &resp); err != nil {
		panic(err)
	}
	fmt.Printf("resp id=%d err=%q result_len=%d\n", resp.GetResponse().GetId(), resp.GetResponse().GetError(), len(resp.GetResponse().GetResultBytes()))
}
