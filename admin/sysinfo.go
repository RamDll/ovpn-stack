package main

import (
	"fmt"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"

	log "github.com/sirupsen/logrus"
)

// serverName возвращает человекочитаемое имя сервера: сначала переменная
// окружения OVPN_SERVER_NAME, затем смонтированный с хоста файл
// /etc/nodename, и в последнюю очередь os.Hostname() (в контейнере это
// обычно id контейнера).
func serverName() string {
	if v := strings.TrimSpace(os.Getenv("OVPN_SERVER_NAME")); v != "" {
		return v
	}
	if b, err := os.ReadFile("/etc/nodename"); err == nil {
		if s := strings.TrimSpace(string(b)); s != "" {
			return s
		}
	}
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "unknown"
}

// loadAvg1 — средняя загрузка за 1 минуту из /proc/loadavg (внутри
// контейнера это значение хоста).
func loadAvg1() float64 {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return v
}

// memInfo возвращает (total, used) в байтах из /proc/meminfo; used считается
// как MemTotal - MemAvailable.
func memInfo() (total, used uint64) {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, 0
	}
	var avail uint64
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		kb, _ := strconv.ParseUint(f[1], 10, 64)
		switch f[0] {
		case "MemTotal:":
			total = kb * 1024
		case "MemAvailable:":
			avail = kb * 1024
		}
	}
	if avail > total {
		avail = total
	}
	return total, total - avail
}

// systemStatsHandler отдаёт имя сервера и текущую загрузку CPU/памяти.
func (oAdmin *OvpnAdmin) systemStatsHandler(w http.ResponseWriter, r *http.Request) {
	log.Debug(r.RemoteAddr, " ", r.RequestURI)
	total, used := memInfo()
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w,
		`{"hostname":%q,"load":%.2f,"cpu":%d,"memTotal":%d,"memUsed":%d}`,
		serverName(), loadAvg1(), runtime.NumCPU(), total, used)
}
