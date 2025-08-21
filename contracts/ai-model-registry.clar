;; AI Model Registry Contract
;; Manages registration, versioning, and metadata for AI models

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-MODEL-NOT-FOUND (err u101))
(define-constant ERR-MODEL-ALREADY-EXISTS (err u102))
(define-constant ERR-INVALID-VERSION (err u103))
(define-constant ERR-INVALID-INPUT (err u104))
(define-constant ERR-MODEL-INACTIVE (err u105))

;; Data Variables
(define-data-var next-model-id uint u1)

;; Data Maps
(define-map models
  { model-id: uint }
  {
    name: (string-ascii 64),
    description: (string-utf8 256),
    owner: principal,
    ipfs-hash: (string-ascii 64),
    version: uint,
    status: (string-ascii 16),
    created-at: uint,
    updated-at: uint
  }
)

(define-map model-versions
  { model-id: uint, version: uint }
  {
    ipfs-hash: (string-ascii 64),
    description: (string-utf8 256),
    created-at: uint,
    performance-score: (optional uint),
    audit-status: (string-ascii 16)
  }
)

(define-map model-permissions
  { model-id: uint, user: principal }
  {
    can-read: bool,
    can-write: bool,
    can-audit: bool,
    granted-at: uint,
    granted-by: principal
  }
)

(define-map model-name-to-id
  { name: (string-ascii 64) }
  { model-id: uint }
)

;; Read-only functions

(define-read-only (get-model (model-id uint))
  (map-get? models { model-id: model-id })
)

(define-read-only (get-model-by-name (name (string-ascii 64)))
  (match (map-get? model-name-to-id { name: name })
    entry (get-model (get model-id entry))
    none
  )
)

(define-read-only (get-model-version (model-id uint) (version uint))
  (map-get? model-versions { model-id: model-id, version: version })
)

(define-read-only (get-user-permissions (model-id uint) (user principal))
  (map-get? model-permissions { model-id: model-id, user: user })
)

(define-read-only (get-next-model-id)
  (var-get next-model-id)
)

(define-read-only (is-model-owner (model-id uint) (user principal))
  (match (get-model model-id)
    model (is-eq (get owner model) user)
    false
  )
)

(define-read-only (has-model-permission (model-id uint) (user principal) (permission (string-ascii 16)))
  (let ((perms (get-user-permissions model-id user)))
    (match perms
      permissions
        (if (is-eq permission "read")
          (get can-read permissions)
          (if (is-eq permission "write")
            (get can-write permissions)
            (if (is-eq permission "audit")
              (get can-audit permissions)
              false
            )
          )
        )
      false
    )
  )
)

;; Private functions

(define-private (is-authorized (model-id uint) (action (string-ascii 16)))
  (let ((caller tx-sender))
    (or
      (is-eq caller CONTRACT-OWNER)
      (is-model-owner model-id caller)
      (has-model-permission model-id caller action)
    )
  )
)

(define-private (validate-model-input (name (string-ascii 64)) (description (string-utf8 256)) (ipfs-hash (string-ascii 64)))
  (and
    (> (len name) u0)
    (< (len name) u65)
    (> (len description) u0)
    (< (len description) u257)
    (> (len ipfs-hash) u0)
    (< (len ipfs-hash) u65)
  )
)

;; Public functions

(define-public (register-model (name (string-ascii 64)) (description (string-utf8 256)) (ipfs-hash (string-ascii 64)))
  (let (
    (model-id (var-get next-model-id))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (validate-model-input name description ipfs-hash) ERR-INVALID-INPUT)
    (asserts! (is-none (map-get? model-name-to-id { name: name })) ERR-MODEL-ALREADY-EXISTS)

    ;; Create model entry
    (map-set models
      { model-id: model-id }
      {
        name: name,
        description: description,
        owner: tx-sender,
        ipfs-hash: ipfs-hash,
        version: u1,
        status: "active",
        created-at: current-time,
        updated-at: current-time
      }
    )

    ;; Create initial version
    (map-set model-versions
      { model-id: model-id, version: u1 }
      {
        ipfs-hash: ipfs-hash,
        description: description,
        created-at: current-time,
        performance-score: none,
        audit-status: "pending"
      }
    )

    ;; Map name to ID
    (map-set model-name-to-id
      { name: name }
      { model-id: model-id }
    )

    ;; Increment next model ID
    (var-set next-model-id (+ model-id u1))

    (ok model-id)
  )
)

(define-public (create-model-version (model-id uint) (ipfs-hash (string-ascii 64)) (description (string-utf8 256)))
  (let (
    (model (unwrap! (get-model model-id) ERR-MODEL-NOT-FOUND))
    (current-version (get version model))
    (new-version (+ current-version u1))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    (asserts! (is-authorized model-id "write") ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status model) "active") ERR-MODEL-INACTIVE)
    (asserts! (and (> (len ipfs-hash) u0) (< (len ipfs-hash) u65)) ERR-INVALID-INPUT)
    (asserts! (and (> (len description) u0) (< (len description) u257)) ERR-INVALID-INPUT)

    ;; Create new version
    (map-set model-versions
      { model-id: model-id, version: new-version }
      {
        ipfs-hash: ipfs-hash,
        description: description,
        created-at: current-time,
        performance-score: none,
        audit-status: "pending"
      }
    )

    ;; Update model with new version and IPFS hash
    (map-set models
      { model-id: model-id }
      (merge model {
        ipfs-hash: ipfs-hash,
        version: new-version,
        updated-at: current-time
      })
    )

    (ok new-version)
  )
)

(define-public (update-model-status (model-id uint) (new-status (string-ascii 16)))
  (let ((model (unwrap! (get-model model-id) ERR-MODEL-NOT-FOUND)))
    (asserts! (is-authorized model-id "write") ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq new-status "active") (is-eq new-status "inactive") (is-eq new-status "deprecated")) ERR-INVALID-INPUT)

    (map-set models
      { model-id: model-id }
      (merge model {
        status: new-status,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )

    (ok true)
  )
)

(define-public (grant-model-permission (model-id uint) (user principal) (can-read bool) (can-write bool) (can-audit bool))
  (let ((current-time (unwrap-panic (get-block-info? time (- block-height u1)))))
    (asserts! (is-some (get-model model-id)) ERR-MODEL-NOT-FOUND)
    (asserts! (is-authorized model-id "write") ERR-NOT-AUTHORIZED)

    (map-set model-permissions
      { model-id: model-id, user: user }
      {
        can-read: can-read,
        can-write: can-write,
        can-audit: can-audit,
        granted-at: current-time,
        granted-by: tx-sender
      }
    )

    (ok true)
  )
)

(define-public (revoke-model-permission (model-id uint) (user principal))
  (begin
    (asserts! (is-some (get-model model-id)) ERR-MODEL-NOT-FOUND)
    (asserts! (is-authorized model-id "write") ERR-NOT-AUTHORIZED)

    (map-delete model-permissions { model-id: model-id, user: user })

    (ok true)
  )
)

(define-public (update-version-performance (model-id uint) (version uint) (performance-score uint))
  (let ((version-data (unwrap! (get-model-version model-id version) ERR-INVALID-VERSION)))
    (asserts! (is-authorized model-id "write") ERR-NOT-AUTHORIZED)
    (asserts! (<= performance-score u10000) ERR-INVALID-INPUT) ;; Max 100.00% (10000 basis points)

    (map-set model-versions
      { model-id: model-id, version: version }
      (merge version-data {
        performance-score: (some performance-score)
      })
    )

    (ok true)
  )
)

(define-public (update-version-audit-status (model-id uint) (version uint) (audit-status (string-ascii 16)))
  (let ((version-data (unwrap! (get-model-version model-id version) ERR-INVALID-VERSION)))
    (asserts! (is-authorized model-id "audit") ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq audit-status "pending") (is-eq audit-status "passed") (is-eq audit-status "failed")) ERR-INVALID-INPUT)

    (map-set model-versions
      { model-id: model-id, version: version }
      (merge version-data {
        audit-status: audit-status
      })
    )

    (ok true)
  )
)

;; Transfer ownership
(define-public (transfer-model-ownership (model-id uint) (new-owner principal))
  (let ((model (unwrap! (get-model model-id) ERR-MODEL-NOT-FOUND)))
    (asserts! (is-model-owner model-id tx-sender) ERR-NOT-AUTHORIZED)

    (map-set models
      { model-id: model-id }
      (merge model {
        owner: new-owner,
        updated-at: (unwrap-panic (get-block-info? time (- block-height u1)))
      })
    )

    (ok true)
  )
)
