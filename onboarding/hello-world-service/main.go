// edge-device-service: Kessel Integration Hello World (Go)
//
// This service demonstrates the complete Kafka CDC Outbox integration pattern
// for a new service integrating with Kessel.
//
// Data flow:
//   POST /api/edge/v1/devices
//     → INSERT device into edge.devices
//     → INSERT ghost-row into edge.outbox     (Debezium captures this from WAL)
//     → DELETE ghost-row from edge.outbox     (same transaction)
//     → COMMIT
//
//   [seconds later, async]
//   Debezium (edge-device-outbox-connector)
//     → reads edge.outbox INSERT from PostgreSQL WAL
//     → publishes to Kafka: outbox.event.edge.devices
//
//   Embedded Kafka consumer goroutine
//     → reads from outbox.event.edge.devices
//     → calls kessel-relations-api HTTP: POST /api/authz/v1beta1/tuples
//     → creates tuple: edge/device:{id}#t_workspace@rbac/workspace:{workspace_id}
//
//   SpiceDB now knows: device belongs to workspace
//
//   POST /api/edge/v1/check
//     → calls kessel-relations-api HTTP: POST /api/authz/v1beta1/check
//     → returns whether principal has permission on device
//
// Run standalone:
//   DB_HOST=localhost KAFKA_BROKERS=localhost:9092 RELATIONS_API_URL=http://localhost:8082 go run main.go
//
// Run via docker compose (from hello-world-service/):
//   docker compose -f compose/docker-compose.yml up --build

package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/IBM/sarama"
	"github.com/google/uuid"
	_ "github.com/lib/pq"
)

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

type Config struct {
	// Database
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string

	// Kafka
	KafkaBrokers []string
	KafkaTopic   string
	KafkaGroupID string

	// Kessel
	RelationsAPIURL    string
	ResourceNamespace  string
	ResourceType       string
	WorkspaceNamespace string
	WorkspaceType      string

	// Server
	ListenAddr string
}

func configFromEnv() Config {
	brokers := os.Getenv("KAFKA_BROKERS")
	if brokers == "" {
		brokers = "localhost:9092"
	}
	return Config{
		DBHost:             getenv("DB_HOST", "localhost"),
		DBPort:             getenv("DB_PORT", "5432"),
		DBUser:             getenv("DB_USER", "edge"),
		DBPassword:         getenv("DB_PASSWORD", "secretpassword"),
		DBName:             getenv("DB_NAME", "edge"),
		KafkaBrokers:       strings.Split(brokers, ","),
		KafkaTopic:         getenv("KAFKA_TOPIC", "outbox.event.edge.devices"),
		KafkaGroupID:       getenv("KAFKA_GROUP_ID", "edge-device-consumer"),
		RelationsAPIURL:    getenv("RELATIONS_API_URL", "http://localhost:8082"),
		ResourceNamespace:  getenv("RESOURCE_NAMESPACE", "edge"),
		ResourceType:       getenv("RESOURCE_TYPE", "device"),
		WorkspaceNamespace: getenv("WORKSPACE_NAMESPACE", "rbac"),
		WorkspaceType:      getenv("WORKSPACE_TYPE", "workspace"),
		ListenAddr:         getenv("LISTEN_ADDR", ":8080"),
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// ---------------------------------------------------------------------------
// Domain types
// ---------------------------------------------------------------------------

// Device is the core resource managed by this service.
type Device struct {
	ID          string    `json:"id"`
	DisplayName string    `json:"display_name"`
	WorkspaceID string    `json:"workspace_id"` // rbac/workspace ID in Kessel
	Reporter    string    `json:"reporter"`
	OrgID       string    `json:"org_id"`
	CreatedAt   time.Time `json:"created_at"`
}

// OutboxPayload is the JSON written to edge.outbox and forwarded to the consumer.
// The consumer reads this from the Kafka topic and calls Relations API with it.
type OutboxPayload struct {
	Type        string `json:"type"`         // SpiceDB type: "edge/device"
	ID          string `json:"id"`           // device UUID
	DisplayName string `json:"display_name"`
	WorkspaceID string `json:"workspace_id"` // rbac/workspace UUID
	Reporter    string `json:"reporter"`
	OrgID       string `json:"org_id"`
	Operation   string `json:"operation"`    // "created" | "updated" | "deleted"
}

// ---------------------------------------------------------------------------
// Database layer
// ---------------------------------------------------------------------------

func openDB(cfg Config) (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
		cfg.DBHost, cfg.DBPort, cfg.DBUser, cfg.DBPassword, cfg.DBName,
	)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	return db, nil
}

// createDevice writes the device record and the outbox ghost-row atomically.
// The ghost-row pattern:
//  1. INSERT into edge.outbox → Debezium captures this INSERT from PostgreSQL WAL
//  2. DELETE from edge.outbox → happens before Debezium processes, but WAL already has the INSERT
//
// This guarantees exactly-once delivery to Kafka: if the transaction commits,
// the INSERT is in the WAL. If it rolls back, nothing was published.
func createDevice(db *sql.DB, device Device) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	// 1. Write the actual device record
	_, err = tx.Exec(`
		INSERT INTO edge.devices (id, display_name, workspace_id, reporter, org_id)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO UPDATE
		  SET display_name = EXCLUDED.display_name,
		      updated_at   = NOW()`,
		device.ID, device.DisplayName, device.WorkspaceID, device.Reporter, device.OrgID,
	)
	if err != nil {
		return fmt.Errorf("insert device: %w", err)
	}

	// 2. Serialize the outbox payload
	payload := OutboxPayload{
		Type:        "edge/device",
		ID:          device.ID,
		DisplayName: device.DisplayName,
		WorkspaceID: device.WorkspaceID,
		Reporter:    device.Reporter,
		OrgID:       device.OrgID,
		Operation:   "created",
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal payload: %w", err)
	}

	// 3. INSERT ghost-row into outbox (Debezium captures this from WAL)
	outboxID := uuid.New().String()
	_, err = tx.Exec(`
		INSERT INTO edge.outbox (id, aggregatetype, aggregateid, type, payload, operation)
		VALUES ($1, 'devices', $2, 'ReportResource', $3::jsonb, 'created')`,
		outboxID, device.ID, string(payloadJSON),
	)
	if err != nil {
		return fmt.Errorf("insert outbox row: %w", err)
	}

	// 4. DELETE ghost-row immediately (Debezium already captured the INSERT above)
	_, err = tx.Exec(`DELETE FROM edge.outbox WHERE id = $1`, outboxID)
	if err != nil {
		return fmt.Errorf("delete outbox row: %w", err)
	}

	return tx.Commit()
}

// deleteDevice removes a device and writes a DeleteResource outbox event.
func deleteDevice(db *sql.DB, deviceID string) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck

	// Look up the device to include workspace_id in the outbox payload
	var workspaceID, reporter, orgID string
	err = tx.QueryRow(
		`SELECT workspace_id, reporter, org_id FROM edge.devices WHERE id = $1`, deviceID,
	).Scan(&workspaceID, &reporter, &orgID)
	if err == sql.ErrNoRows {
		return fmt.Errorf("device not found: %s", deviceID)
	}
	if err != nil {
		return fmt.Errorf("query device: %w", err)
	}

	// Delete the actual device record
	_, err = tx.Exec(`DELETE FROM edge.devices WHERE id = $1`, deviceID)
	if err != nil {
		return fmt.Errorf("delete device: %w", err)
	}

	// Write the DeleteResource outbox ghost-row
	payload := OutboxPayload{
		Type:        "edge/device",
		ID:          deviceID,
		WorkspaceID: workspaceID,
		Reporter:    reporter,
		OrgID:       orgID,
		Operation:   "deleted",
	}
	payloadJSON, _ := json.Marshal(payload)

	outboxID := uuid.New().String()
	_, err = tx.Exec(`
		INSERT INTO edge.outbox (id, aggregatetype, aggregateid, type, payload, operation)
		VALUES ($1, 'devices', $2, 'DeleteResource', $3::jsonb, 'deleted')`,
		outboxID, deviceID, string(payloadJSON),
	)
	if err != nil {
		return fmt.Errorf("insert delete outbox row: %w", err)
	}
	_, err = tx.Exec(`DELETE FROM edge.outbox WHERE id = $1`, outboxID)
	if err != nil {
		return fmt.Errorf("delete outbox row: %w", err)
	}

	return tx.Commit()
}

func listDevices(db *sql.DB) ([]Device, error) {
	rows, err := db.Query(
		`SELECT id, display_name, workspace_id, reporter, org_id, created_at
		 FROM edge.devices ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var devices []Device
	for rows.Next() {
		var d Device
		if err := rows.Scan(&d.ID, &d.DisplayName, &d.WorkspaceID, &d.Reporter, &d.OrgID, &d.CreatedAt); err != nil {
			return nil, err
		}
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

func getDevice(db *sql.DB, id string) (*Device, error) {
	var d Device
	err := db.QueryRow(
		`SELECT id, display_name, workspace_id, reporter, org_id, created_at
		 FROM edge.devices WHERE id = $1`, id,
	).Scan(&d.ID, &d.DisplayName, &d.WorkspaceID, &d.Reporter, &d.OrgID, &d.CreatedAt)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return &d, err
}

// ---------------------------------------------------------------------------
// Kessel Relations API client
// ---------------------------------------------------------------------------

// Tuple represents a SpiceDB relationship tuple.
// POST /api/authz/v1beta1/tuples  body: {"tuples": [...]}
//
// The Relations API (protobuf JSON encoding) wraps the subject in a SubjectReference:
//   "subject": {"subject": {"type": {...}, "id": "..."}}
type Tuple struct {
	Resource TupleObject      `json:"resource"`
	Relation string           `json:"relation"`
	Subject  SubjectReference `json:"subject"`
}

// SubjectReference is the protobuf-JSON encoding of the subject oneof field.
// The outer key "subject" is the oneof variant name.
type SubjectReference struct {
	Subject TupleObject `json:"subject"`
}

type TupleObject struct {
	Type ObjectType `json:"type"`
	ID   string     `json:"id"`
}

type ObjectType struct {
	Namespace string `json:"namespace"`
	Name      string `json:"name"`
}

type CreateTuplesRequest struct {
	Upsert bool    `json:"upsert"`
	Tuples []Tuple `json:"tuples"`
}

type DeleteTuplesRequest struct {
	Tuples []Tuple `json:"tuples"`
}

// CheckRequest matches the Relations API CheckPermission HTTP body.
// The subject field uses the SubjectReference wrapper (protobuf JSON oneof).
// "relation" is required by the Relations API — it identifies the permission to check.
type CheckRequest struct {
	Resource   TupleObject      `json:"resource"`
	Relation   string           `json:"relation"`
	Permission string           `json:"permission"`
	Subject    SubjectReference `json:"subject"`
}

// CheckResponse is the Relations API v1beta1 check response.
// The response field is "allowed", not "permissionCheckResponse".
type CheckResponse struct {
	Allowed string `json:"allowed"` // "ALLOWED_TRUE" | "ALLOWED_FALSE"
}

// RelationsClient calls kessel-relations-api over HTTP.
type RelationsClient struct {
	baseURL    string
	httpClient *http.Client
	cfg        Config
}

func newRelationsClient(cfg Config) *RelationsClient {
	return &RelationsClient{
		baseURL:    cfg.RelationsAPIURL,
		httpClient: &http.Client{Timeout: 10 * time.Second},
		cfg:        cfg,
	}
}

func (c *RelationsClient) createTuple(resourceID, workspaceID string) error {
	body := CreateTuplesRequest{
		Upsert: true,
		Tuples: []Tuple{
			{
				Resource: TupleObject{
					Type: ObjectType{Namespace: c.cfg.ResourceNamespace, Name: c.cfg.ResourceType},
					ID:   resourceID,
				},
				Relation: "t_workspace",
				Subject: SubjectReference{Subject: TupleObject{
					Type: ObjectType{Namespace: c.cfg.WorkspaceNamespace, Name: c.cfg.WorkspaceType},
					ID:   workspaceID,
				}},
			},
		},
	}
	return c.post("/api/authz/v1beta1/tuples", body)
}

func (c *RelationsClient) deleteTuple(resourceID, workspaceID string) error {
	body := DeleteTuplesRequest{
		Tuples: []Tuple{
			{
				Resource: TupleObject{
					Type: ObjectType{Namespace: c.cfg.ResourceNamespace, Name: c.cfg.ResourceType},
					ID:   resourceID,
				},
				Relation: "t_workspace",
				Subject: SubjectReference{Subject: TupleObject{
					Type: ObjectType{Namespace: c.cfg.WorkspaceNamespace, Name: c.cfg.WorkspaceType},
					ID:   workspaceID,
				}},
			},
		},
	}
	return c.post("/api/authz/v1beta1/tuples/delete", body)
}

func (c *RelationsClient) checkPermission(resourceID, permission, subjectID string) (bool, error) {
	body := CheckRequest{
		Resource: TupleObject{
			Type: ObjectType{Namespace: c.cfg.ResourceNamespace, Name: c.cfg.ResourceType},
			ID:   resourceID,
		},
		Relation:   permission, // Relations API requires both relation and permission
		Permission: permission,
		Subject: SubjectReference{Subject: TupleObject{
			Type: ObjectType{Namespace: "rbac", Name: "principal"},
			ID:   subjectID,
		}},
	}

	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return false, err
	}

	resp, err := c.httpClient.Post(
		c.baseURL+"/api/authz/v1beta1/check",
		"application/json",
		bytes.NewReader(bodyJSON),
	)
	if err != nil {
		return false, fmt.Errorf("check request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return false, fmt.Errorf("relations API check returned %d", resp.StatusCode)
	}

	var result CheckResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return false, fmt.Errorf("decode check response: %w", err)
	}

	return result.Allowed == "ALLOWED_TRUE", nil
}

func (c *RelationsClient) post(path string, body interface{}) error {
	bodyJSON, err := json.Marshal(body)
	if err != nil {
		return err
	}
	resp, err := c.httpClient.Post(
		c.baseURL+path, "application/json", bytes.NewReader(bodyJSON),
	)
	if err != nil {
		return fmt.Errorf("POST %s: %w", path, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 300 {
		return fmt.Errorf("POST %s returned %d", path, resp.StatusCode)
	}
	return nil
}

// ---------------------------------------------------------------------------
// Kafka consumer
// ---------------------------------------------------------------------------

// DeviceConsumer reads from the outbox.event.edge.devices Kafka topic and
// creates/deletes SpiceDB tuples via the Relations API.
//
// This is the "Stage 1 consumer" in the two-stage outbox pipeline:
//   Kafka topic → consumer → Relations API → SpiceDB
//
// In production you would use project-kessel/inventory-consumer instead,
// configured to call kessel-inventory-api (which handles the SpiceDB write).
// This custom consumer shows exactly what the consumer does, step by step.
type DeviceConsumer struct {
	relationsClient *RelationsClient
	brokers         []string
	topic           string
	groupID         string
}

func newDeviceConsumer(cfg Config, relationsClient *RelationsClient) *DeviceConsumer {
	return &DeviceConsumer{
		relationsClient: relationsClient,
		brokers:         cfg.KafkaBrokers,
		topic:           cfg.KafkaTopic,
		groupID:         cfg.KafkaGroupID,
	}
}

// Run starts the consumer loop. It blocks until ctx is cancelled.
func (c *DeviceConsumer) Run(ctx context.Context) {
	cfg := sarama.NewConfig()
	cfg.Consumer.Group.Rebalance.GroupStrategies = []sarama.BalanceStrategy{sarama.NewBalanceStrategyRoundRobin()}
	cfg.Consumer.Offsets.Initial = sarama.OffsetOldest
	cfg.Consumer.Offsets.AutoCommit.Enable = false // manual commit after processing

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		client, err := sarama.NewConsumerGroup(c.brokers, c.groupID, cfg)
		if err != nil {
			log.Printf("[consumer] failed to connect to Kafka (%s), retrying in 5s: %v", strings.Join(c.brokers, ","), err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
				continue
			}
		}

		log.Printf("[consumer] connected to Kafka, subscribing to topic: %s", c.topic)

		handler := &consumerGroupHandler{relationsClient: c.relationsClient}
		for {
			if err := client.Consume(ctx, []string{c.topic}, handler); err != nil {
				log.Printf("[consumer] consume error: %v", err)
			}
			if ctx.Err() != nil {
				break
			}
		}
		client.Close() //nolint:errcheck
	}
}

type consumerGroupHandler struct {
	relationsClient *RelationsClient
}

func (h *consumerGroupHandler) Setup(_ sarama.ConsumerGroupSession) error   { return nil }
func (h *consumerGroupHandler) Cleanup(_ sarama.ConsumerGroupSession) error { return nil }

func (h *consumerGroupHandler) ConsumeClaim(session sarama.ConsumerGroupSession, claim sarama.ConsumerGroupClaim) error {
	for msg := range claim.Messages() {
		if err := h.processMessage(msg); err != nil {
			log.Printf("[consumer] failed to process message offset=%d: %v", msg.Offset, err)
			// Do not commit — message will be reprocessed on restart.
			// In production: implement exponential backoff here.
			continue
		}
		// Only commit offset after successful processing
		session.MarkMessage(msg, "")
		session.Commit()
	}
	return nil
}

// processMessage parses the outbox event and creates or deletes the SpiceDB tuple.
//
// The Kafka message value is the JSON payload from the outbox table (after EventRouter expansion).
// For our outbox, this is the OutboxPayload struct serialized to JSON.
func (h *consumerGroupHandler) processMessage(msg *sarama.ConsumerMessage) error {
	var payload OutboxPayload
	if err := json.Unmarshal(msg.Value, &payload); err != nil {
		return fmt.Errorf("unmarshal payload: %w", err)
	}

	// Determine the operation from the Kafka message headers (set by EventRouter from the 'operation' column)
	operation := "created"
	for _, hdr := range msg.Headers {
		if string(hdr.Key) == "operation" {
			operation = string(hdr.Value)
		}
	}
	// Fall back to payload.Operation if header is missing
	if operation == "" && payload.Operation != "" {
		operation = payload.Operation
	}

	log.Printf("[consumer] %s device=%s workspace=%s", operation, payload.ID, payload.WorkspaceID)

	switch operation {
	case "created", "updated":
		// Create (or upsert) the SpiceDB tuple: edge/device:{id}#t_workspace@rbac/workspace:{workspace_id}
		if err := h.relationsClient.createTuple(payload.ID, payload.WorkspaceID); err != nil {
			return fmt.Errorf("createTuple device=%s workspace=%s: %w", payload.ID, payload.WorkspaceID, err)
		}
		log.Printf("[consumer] created tuple: edge/device:%s#t_workspace@rbac/workspace:%s",
			payload.ID, payload.WorkspaceID)

	case "deleted":
		// Delete the SpiceDB tuple
		if err := h.relationsClient.deleteTuple(payload.ID, payload.WorkspaceID); err != nil {
			return fmt.Errorf("deleteTuple device=%s workspace=%s: %w", payload.ID, payload.WorkspaceID, err)
		}
		log.Printf("[consumer] deleted tuple: edge/device:%s#t_workspace@rbac/workspace:%s",
			payload.ID, payload.WorkspaceID)

	default:
		log.Printf("[consumer] unknown operation %q for device=%s, skipping", operation, payload.ID)
	}

	return nil
}

// ---------------------------------------------------------------------------
// HTTP handlers
// ---------------------------------------------------------------------------

type server struct {
	db              *sql.DB
	relationsClient *RelationsClient
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v) //nolint:errcheck
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

// POST /api/edge/v1/devices
// Body: {"display_name": "My Device", "workspace_id": "ws-uuid", "org_id": "12345"}
func (s *server) handleCreateDevice(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req struct {
		DisplayName string `json:"display_name"`
		WorkspaceID string `json:"workspace_id"`
		OrgID       string `json:"org_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.DisplayName == "" || req.WorkspaceID == "" {
		writeError(w, http.StatusBadRequest, "display_name and workspace_id are required")
		return
	}

	device := Device{
		ID:          uuid.New().String(),
		DisplayName: req.DisplayName,
		WorkspaceID: req.WorkspaceID,
		Reporter:    "edge-device-service",
		OrgID:       req.OrgID,
	}
	if device.OrgID == "" {
		device.OrgID = "12345"
	}

	if err := createDevice(s.db, device); err != nil {
		log.Printf("createDevice: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to create device")
		return
	}

	log.Printf("device created: id=%s workspace=%s (outbox ghost-row written)", device.ID, device.WorkspaceID)
	writeJSON(w, http.StatusCreated, device)
}

// GET /api/edge/v1/devices
func (s *server) handleListDevices(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	devices, err := listDevices(s.db)
	if err != nil {
		log.Printf("listDevices: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to list devices")
		return
	}
	if devices == nil {
		devices = []Device{}
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"count": len(devices),
		"data":  devices,
	})
}

// GET /api/edge/v1/devices/{id}
func (s *server) handleGetDevice(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	device, err := getDevice(s.db, id)
	if err != nil {
		log.Printf("getDevice %s: %v", id, err)
		writeError(w, http.StatusInternalServerError, "failed to get device")
		return
	}
	if device == nil {
		writeError(w, http.StatusNotFound, "device not found")
		return
	}
	writeJSON(w, http.StatusOK, device)
}

// DELETE /api/edge/v1/devices/{id}
func (s *server) handleDeleteDevice(w http.ResponseWriter, r *http.Request, id string) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	if err := deleteDevice(s.db, id); err != nil {
		log.Printf("deleteDevice %s: %v", id, err)
		if strings.Contains(err.Error(), "not found") {
			writeError(w, http.StatusNotFound, "device not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "failed to delete device")
		return
	}

	w.WriteHeader(http.StatusNoContent)
}

// POST /api/edge/v1/check
// Body: {"device_id": "...", "permission": "view", "subject_id": "alice"}
// This demonstrates how your service would call Kessel to authorize a request.
func (s *server) handleCheck(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req struct {
		DeviceID   string `json:"device_id"`
		Permission string `json:"permission"`
		SubjectID  string `json:"subject_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.DeviceID == "" || req.Permission == "" || req.SubjectID == "" {
		writeError(w, http.StatusBadRequest, "device_id, permission, and subject_id are required")
		return
	}

	permitted, err := s.relationsClient.checkPermission(req.DeviceID, req.Permission, req.SubjectID)
	if err != nil {
		log.Printf("checkPermission device=%s perm=%s subject=%s: %v", req.DeviceID, req.Permission, req.SubjectID, err)
		writeError(w, http.StatusInternalServerError, "permission check failed")
		return
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"device_id":  req.DeviceID,
		"permission": req.Permission,
		"subject_id": req.SubjectID,
		"permitted":  permitted,
	})
}

// GET /health  — liveness probe
func handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// GET /ready  — readiness probe (checks DB connectivity)
func handleReady(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := db.PingContext(r.Context()); err != nil {
			writeError(w, http.StatusServiceUnavailable, "database not ready")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
	}
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------

func (s *server) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/ready", handleReady(s.db))

	mux.HandleFunc("/api/edge/v1/devices", func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			s.handleCreateDevice(w, r)
		case http.MethodGet:
			s.handleListDevices(w, r)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	})

	mux.HandleFunc("/api/edge/v1/devices/", func(w http.ResponseWriter, r *http.Request) {
		// Extract ID from path: /api/edge/v1/devices/{id}
		id := strings.TrimPrefix(r.URL.Path, "/api/edge/v1/devices/")
		if id == "" {
			writeError(w, http.StatusBadRequest, "missing device id")
			return
		}
		switch r.Method {
		case http.MethodGet:
			s.handleGetDevice(w, r, id)
		case http.MethodDelete:
			s.handleDeleteDevice(w, r, id)
		default:
			writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		}
	})

	mux.HandleFunc("/api/edge/v1/check", s.handleCheck)

	return mux
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Println("[main] edge-device-service starting")

	cfg := configFromEnv()

	// Open database (with retry to handle cold-start ordering)
	var db *sql.DB
	var err error
	for i := 0; i < 30; i++ {
		db, err = openDB(cfg)
		if err == nil {
			if err = db.PingContext(context.Background()); err == nil {
				break
			}
		}
		log.Printf("[main] waiting for database (%s:%s/%s)... %v", cfg.DBHost, cfg.DBPort, cfg.DBName, err)
		time.Sleep(2 * time.Second)
	}
	if err != nil {
		log.Fatalf("[main] cannot connect to database: %v", err)
	}
	log.Printf("[main] connected to database %s:%s/%s", cfg.DBHost, cfg.DBPort, cfg.DBName)

	relationsClient := newRelationsClient(cfg)

	// Start the Kafka consumer in the background.
	// It reads from outbox.event.edge.devices and creates SpiceDB tuples.
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	consumer := newDeviceConsumer(cfg, relationsClient)
	go consumer.Run(ctx)

	// Start the HTTP server
	srv := &server{db: db, relationsClient: relationsClient}
	httpServer := &http.Server{
		Addr:         cfg.ListenAddr,
		Handler:      srv.routes(),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
	}

	// Graceful shutdown on SIGTERM / SIGINT
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigCh
		log.Println("[main] shutting down...")
		cancel()
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer shutdownCancel()
		httpServer.Shutdown(shutdownCtx) //nolint:errcheck
	}()

	log.Printf("[main] HTTP server listening on %s", cfg.ListenAddr)
	log.Printf("[main] Kafka consumer subscribed to: %s", cfg.KafkaTopic)
	log.Printf("[main] Relations API: %s", cfg.RelationsAPIURL)

	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("[main] server error: %v", err)
	}
	log.Println("[main] stopped")
}
