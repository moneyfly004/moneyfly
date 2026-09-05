package main

import (
	"fmt"
	"os"
	"time"

	"moneyfly/mihomelib"
)

func main() {
	yaml := `mixed-port: 27080
external-controller: 127.0.0.1:27090
mode: rule
log-level: info
dns:
  enable: true
  nameserver: [223.5.5.5]
proxies:
  - {name: n1, type: ss, server: 1.2.3.4, port: 8388, password: p, cipher: aes-256-gcm}
proxy-groups:
  - {name: select, type: select, proxies: [n1, DIRECT]}
rules:
  - MATCH,select
`
	dir, _ := os.MkdirTemp("", "mf_log")
	defer os.RemoveAll(dir)
	if err := mihomelib.Start(dir, []byte(yaml), 0); err != nil {
		fmt.Println("Start err:", err)
		os.Exit(1)
	}
	time.Sleep(1200 * time.Millisecond)
	l1 := mihomelib.Logs()
	fmt.Printf("首拉(应含启动日志, %d 字符):\n%s\n", len(l1), l1)
	time.Sleep(600 * time.Millisecond)
	l2 := mihomelib.Logs()
	fmt.Printf("二拉增量 %d 字符\n", l2)
	mihomelib.Stop()
	time.Sleep(300 * time.Millisecond)
	l3 := mihomelib.Logs()
	fmt.Printf("停止后增量 %d 字符\n", l3)
	fmt.Println("LOG TEST PASS")
}
