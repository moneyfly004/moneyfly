package main

import (
	"fmt"
	"net/http"
	"os"
	"time"

	"moneyfly/mihomelib"
)

func main() {
	yaml := `mixed-port: 26080
external-controller: 127.0.0.1:26090
mode: rule
log-level: warning
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
	dir, _ := os.MkdirTemp("", "mihost")
	defer os.RemoveAll(dir)
	for i := 1; i <= 6; i++ {
		if err := mihomelib.Start(dir, []byte(yaml), 0); err != nil {
			fmt.Printf("round %d Start FAILED: %v\n", i, err)
			os.Exit(1)
		}
		ok := false
		for j := 0; j < 50; j++ {
			resp, err := http.Get("http://127.0.0.1:26090/version")
			if err == nil {
				resp.Body.Close()
				if resp.StatusCode == 200 {
					ok = true
					break
				}
			}
			time.Sleep(100 * time.Millisecond)
		}
		if !ok {
			fmt.Printf("round %d: /version 不可达(启动失败/端口占用?)\n", i)
			os.Exit(1)
		}
		fmt.Printf("round %d: 内核启动 OK -> ", i)
		mihomelib.Stop()
		fmt.Printf("已停止\n")
		time.Sleep(400 * time.Millisecond)
	}
	fmt.Println("PASS: 6 轮 start/stop 循环全部通过(库模式断开再连幂等)")
}
