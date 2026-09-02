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

const (
	statBucket     = "traffic_monthly"
	dailyBucket    = "traffic_daily"
	lastSeenBucket = "last_seen"
	dailyKeepDays  = 45 // сколько дней истории держим в бакете traffic_daily
)

type monthBytes struct {
	Rx uint64 `json:"rx"`
	Tx uint64 `json:"tx"`
}

type statStore struct {
	db       *bolt.DB
	mu       sync.Mutex
	seen     map[string]monthBytes // последние сессионные счётчики по каждому активному CN
	lastSeen map[string]int64      // unix-время последнего появления онлайн по CN
}

func newStatStore(path string) *statStore {
	s := &statStore{seen: make(map[string]monthBytes), lastSeen: make(map[string]int64)}
	if path == "" {
		return s
	}
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: 3 * time.Second})
	if err != nil {
		log.Warnf("statistic: не удалось открыть %s: %v — статистика без сохранения", path, err)
		return s
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		if _, e := tx.CreateBucketIfNotExists([]byte(statBucket)); e != nil {
			return e
		}
		if _, e := tx.CreateBucketIfNotExists([]byte(dailyBucket)); e != nil {
			return e
		}
		_, e := tx.CreateBucketIfNotExists([]byte(lastSeenBucket))
		return e
	}); err != nil {
		log.Warnf("statistic: init bucket: %v", err)
		_ = db.Close()
		return s
	}
	s.db = db
	// поднять last_seen из bbolt в память
	_ = db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(lastSeenBucket))
		return b.ForEach(func(k, v []byte) error {
			var ts int64
			if json.Unmarshal(v, &ts) == nil {
				s.lastSeen[string(k)] = ts
			}
			return nil
		})
	})
	log.Infof("statistic: хранилище трафика — %s", path)
	return s
}

// lastSeenOf — unix-время последнего появления клиента онлайн (0 — не видели)
func (s *statStore) lastSeenOf(cn string) int64 {
	if s == nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastSeen[cn]
}

func currentMonth() string { return time.Now().UTC().Format("2006-01") }
func currentDay() string   { return time.Now().UTC().Format("2006-01-02") }

// record вызывается на каждом опросе mgmt-интерфейса со списком активных клиентов.
func (s *statStore) record(active []clientStatus) {
	if s == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now().Unix()
	online := make(map[string]bool, len(active))
	for _, c := range active {
		rx, _ := strconv.ParseUint(c.BytesReceived, 10, 64)
		tx, _ := strconv.ParseUint(c.BytesSent, 10, 64)
		online[c.CommonName] = true
		s.lastSeen[c.CommonName] = now
		if s.db != nil {
			enc, _ := json.Marshal(now)
			_ = s.db.Update(func(tx *bolt.Tx) error {
				return tx.Bucket([]byte(lastSeenBucket)).Put([]byte(c.CommonName), enc)
			})
		}

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
		s.addToDay(c.CommonName, dRx, dTx)
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

func (s *statStore) addToDay(cn string, dRx, dTx uint64) {
	if s.db == nil {
		return
	}
	day := currentDay()
	cutoff := time.Now().UTC().AddDate(0, 0, -dailyKeepDays).Format("2006-01-02")
	err := s.db.Update(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(dailyBucket))
		days := map[string]monthBytes{}
		if raw := b.Get([]byte(cn)); raw != nil {
			_ = json.Unmarshal(raw, &days)
		}
		for d := range days {
			if d < cutoff {
				delete(days, d)
			}
		}
		mb := days[day]
		mb.Rx += dRx
		mb.Tx += dTx
		days[day] = mb
		enc, e := json.Marshal(days)
		if e != nil {
			return e
		}
		return b.Put([]byte(cn), enc)
	})
	if err != nil {
		log.Warnf("statistic: запись дня %s: %v", cn, err)
	}
}

// todayTotal — суммарный трафик всех клиентов за текущие сутки (UTC).
func (s *statStore) todayTotal() (rx, tx uint64) {
	if s == nil || s.db == nil {
		return 0, 0
	}
	day := currentDay()
	_ = s.db.View(func(dbtx *bolt.Tx) error {
		b := dbtx.Bucket([]byte(dailyBucket))
		return b.ForEach(func(k, v []byte) error {
			days := map[string]monthBytes{}
			if json.Unmarshal(v, &days) != nil {
				return nil
			}
			if d, ok := days[day]; ok {
				rx += d.Rx
				tx += d.Tx
			}
			return nil
		})
	})
	return rx, tx
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
