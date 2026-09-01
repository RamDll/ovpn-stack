package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	log "github.com/sirupsen/logrus"
	bolt "go.etcd.io/bbolt"
)

// Накопительная статистика трафика по месяцам.
//
// OpenVPN management-интерфейс отдаёт только счётчики текущей сессии подключённого
// клиента; при отключении они пропадают. Здесь на каждом опросе считается прирост
// байт по каждому активному клиенту и складывается в помесячные бакеты (bbolt),
// а также в Prometheus-счётчики ovpn_client_traffic_{received,sent}_total.

var (
	ovpnClientTrafficReceivedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "ovpn_client_traffic_received_total",
		Help: "openvpn user total bytes received (accumulated across sessions)",
	}, []string{"client"})

	ovpnClientTrafficSentTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "ovpn_client_traffic_sent_total",
		Help: "openvpn user total bytes sent (accumulated across sessions)",
	}, []string{"client"})
)

const statBucket = "traffic_monthly"

type monthBytes struct {
	Rx uint64 `json:"rx"`
	Tx uint64 `json:"tx"`
}

type statStore struct {
	db   *bolt.DB
	mu   sync.Mutex
	seen map[string]monthBytes // последние сессионные счётчики по каждому активному CN
}

func newStatStore(path string) *statStore {
	s := &statStore{seen: make(map[string]monthBytes)}
	if path == "" {
		return s
	}
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: 3 * time.Second})
	if err != nil {
		log.Warnf("statistic: не удалось открыть %s: %v — статистика без сохранения", path, err)
		return s
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		_, e := tx.CreateBucketIfNotExists([]byte(statBucket))
		return e
	}); err != nil {
		log.Warnf("statistic: init bucket: %v", err)
		_ = db.Close()
		return s
	}
	s.db = db
	log.Infof("statistic: хранилище трафика — %s", path)
	return s
}

func currentMonth() string { return time.Now().UTC().Format("2006-01") }

// record вызывается на каждом опросе mgmt-интерфейса со списком активных клиентов.
func (s *statStore) record(active []clientStatus) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	online := make(map[string]bool, len(active))
	for _, c := range active {
		rx, _ := strconv.ParseUint(c.BytesReceived, 10, 64)
		tx, _ := strconv.ParseUint(c.BytesSent, 10, 64)
		online[c.CommonName] = true

		prev, known := s.seen[c.CommonName]
		var dRx, dTx uint64
		if known && rx >= prev.Rx {
			dRx = rx - prev.Rx
		} else {
			dRx = rx // новый клиент или переподключение (счётчик упал) — берём всё текущее
		}
		if known && tx >= prev.Tx {
			dTx = tx - prev.Tx
		} else {
			dTx = tx
		}
		s.seen[c.CommonName] = monthBytes{Rx: rx, Tx: tx}

		if dRx == 0 && dTx == 0 {
			continue
		}
		ovpnClientTrafficReceivedTotal.WithLabelValues(c.CommonName).Add(float64(dRx))
		ovpnClientTrafficSentTotal.WithLabelValues(c.CommonName).Add(float64(dTx))
		s.addToMonth(c.CommonName, dRx, dTx)
	}

	// клиенты, которых больше нет онлайн — забываем сессионные счётчики,
	// чтобы следующее подключение считалось с нуля
	for cn := range s.seen {
		if !online[cn] {
			delete(s.seen, cn)
		}
	}
}

func (s *statStore) addToMonth(cn string, dRx, dTx uint64) {
	if s.db == nil {
		return
	}
	month := currentMonth()
	err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(statBucket))
		months := map[string]monthBytes{}
		if raw := b.Get([]byte(cn)); raw != nil {
			_ = json.Unmarshal(raw, &months)
		}
		mb := months[month]
		mb.Rx += dRx
		mb.Tx += dTx
		months[month] = mb
		enc, e := json.Marshal(months)
		if e != nil {
			return e
		}
		return b.Put([]byte(cn), enc)
	})
	if err != nil {
		log.Warnf("statistic: запись %s: %v", cn, err)
	}
}

type userMonthly struct {
	User   string                `json:"user"`
	Months map[string]monthBytes `json:"months"`
}

func (s *statStore) snapshot() []userMonthly {
	out := []userMonthly{}
	if s == nil || s.db == nil {
		return out
	}
	_ = s.db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(statBucket))
		return b.ForEach(func(k, v []byte) error {
			months := map[string]monthBytes{}
			if e := json.Unmarshal(v, &months); e != nil {
				return nil
			}
			out = append(out, userMonthly{User: string(k), Months: months})
			return nil
		})
	})
	return out
}

// GET api/statistic → { monthly: [...], session: { cn: {rx,tx} } }
func (oAdmin *OvpnAdmin) statisticHandler(w http.ResponseWriter, r *http.Request) {
	log.Info(r.RemoteAddr, " ", r.RequestURI)
	session := map[string]monthBytes{}
	for _, c := range oAdmin.activeClients {
		rx, _ := strconv.ParseUint(c.BytesReceived, 10, 64)
		tx, _ := strconv.ParseUint(c.BytesSent, 10, 64)
		session[c.CommonName] = monthBytes{Rx: rx, Tx: tx}
	}
	resp := struct {
		Monthly []userMonthly         `json:"monthly"`
		Session map[string]monthBytes `json:"session"`
	}{
		Monthly: oAdmin.stat.snapshot(),
		Session: session,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}
