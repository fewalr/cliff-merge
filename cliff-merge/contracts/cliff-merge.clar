;; CliffMerge - Cross-Chain Resource Allocation Protocol
;; Core smart contract for validator staking and resource management

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-insufficient-stake (err u101))
(define-constant err-validator-exists (err u102))
(define-constant err-validator-not-found (err u103))
(define-constant err-insufficient-balance (err u104))
(define-constant err-invalid-amount (err u105))
(define-constant err-resource-not-found (err u106))
(define-constant err-unauthorized (err u107))

;; Minimum stake required to become a validator (1000 STX)
(define-constant min-validator-stake u1000000000)

;; Data Variables
(define-data-var total-staked uint u0)
(define-data-var total-validators uint u0)
(define-data-var protocol-fee-percentage uint u250) ;; 2.5% in basis points

;; Data Maps
(define-map validators
    principal
    {
        stake-amount: uint,
        reputation-score: uint,
        total-resources-provided: uint,
        active: bool,
        joined-at: uint
    }
)

(define-map resources
    uint
    {
        provider: principal,
        resource-type: (string-ascii 20),
        capacity: uint,
        price-per-unit: uint,
        allocated: uint,
        available: bool
    }
)

(define-map dapp-allocations
    {dapp: principal, resource-id: uint}
    {
        allocated-amount: uint,
        start-block: uint,
        end-block: uint,
        total-paid: uint
    }
)

(define-data-var resource-nonce uint u0)

;; Read-only functions
(define-read-only (get-validator (validator principal))
    (map-get? validators validator)
)

(define-read-only (get-resource (resource-id uint))
    (map-get? resources resource-id)
)

(define-read-only (get-allocation (dapp principal) (resource-id uint))
    (map-get? dapp-allocations {dapp: dapp, resource-id: resource-id})
)

(define-read-only (get-total-staked)
    (ok (var-get total-staked))
)

(define-read-only (get-total-validators)
    (ok (var-get total-validators))
)

(define-read-only (get-protocol-fee)
    (ok (var-get protocol-fee-percentage))
)

(define-read-only (is-validator (address principal))
    (match (map-get? validators address)
        validator (ok (get active validator))
        (ok false)
    )
)

;; Public functions

;; Register as a validator by staking tokens
(define-public (register-validator (stake-amount uint))
    (let
        (
            (caller tx-sender)
            (existing-validator (map-get? validators caller))
        )
        (asserts! (>= stake-amount min-validator-stake) err-insufficient-stake)
        (asserts! (is-none existing-validator) err-validator-exists)
        
        ;; Transfer stake to contract
        (try! (stx-transfer? stake-amount caller (as-contract tx-sender)))
        
        ;; Register validator
        (map-set validators caller {
            stake-amount: stake-amount,
            reputation-score: u100,
            total-resources-provided: u0,
            active: true,
            joined-at: block-height
        })
        
        ;; Update totals
        (var-set total-staked (+ (var-get total-staked) stake-amount))
        (var-set total-validators (+ (var-get total-validators) u1))
        
        (ok true)
    )
)

;; Add additional stake
(define-public (add-stake (additional-amount uint))
    (let
        (
            (caller tx-sender)
            (validator-data (unwrap! (map-get? validators caller) err-validator-not-found))
        )
        (asserts! (> additional-amount u0) err-invalid-amount)
        
        ;; Transfer additional stake
        (try! (stx-transfer? additional-amount caller (as-contract tx-sender)))
        
        ;; Update validator stake
        (map-set validators caller
            (merge validator-data {
                stake-amount: (+ (get stake-amount validator-data) additional-amount)
            })
        )
        
        ;; Update total staked
        (var-set total-staked (+ (var-get total-staked) additional-amount))
        
        (ok true)
    )
)

;; Register a computational resource
(define-public (register-resource 
    (resource-type (string-ascii 20))
    (capacity uint)
    (price-per-unit uint))
    (let
        (
            (caller tx-sender)
            (validator-data (unwrap! (map-get? validators caller) err-validator-not-found))
            (new-resource-id (var-get resource-nonce))
        )
        (asserts! (get active validator-data) err-unauthorized)
        (asserts! (> capacity u0) err-invalid-amount)
        
        ;; Create resource entry
        (map-set resources new-resource-id {
            provider: caller,
            resource-type: resource-type,
            capacity: capacity,
            price-per-unit: price-per-unit,
            allocated: u0,
            available: true
        })
        
        ;; Increment resource counter
        (var-set resource-nonce (+ new-resource-id u1))
        
        ;; Update validator stats
        (map-set validators caller
            (merge validator-data {
                total-resources-provided: (+ (get total-resources-provided validator-data) u1)
            })
        )
        
        (ok new-resource-id)
    )
)

;; Allocate resources for a dApp
(define-public (allocate-resource 
    (resource-id uint)
    (amount uint)
    (duration-blocks uint))
    (let
        (
            (caller tx-sender)
            (resource-data (unwrap! (map-get? resources resource-id) err-resource-not-found))
            (available-capacity (- (get capacity resource-data) (get allocated resource-data)))
            (total-cost (* (* amount (get price-per-unit resource-data)) duration-blocks))
            (fee-amount (/ (* total-cost (var-get protocol-fee-percentage)) u10000))
            (provider-payment (- total-cost fee-amount))
        )
        (asserts! (get available resource-data) err-resource-not-found)
        (asserts! (<= amount available-capacity) err-insufficient-balance)
        
        ;; Transfer payment
        (try! (stx-transfer? total-cost caller (as-contract tx-sender)))
        (try! (as-contract (stx-transfer? provider-payment tx-sender (get provider resource-data))))
        
        ;; Update resource allocation
        (map-set resources resource-id
            (merge resource-data {
                allocated: (+ (get allocated resource-data) amount)
            })
        )
        
        ;; Record allocation
        (map-set dapp-allocations 
            {dapp: caller, resource-id: resource-id}
            {
                allocated-amount: amount,
                start-block: block-height,
                end-block: (+ block-height duration-blocks),
                total-paid: total-cost
            }
        )
        
        (ok true)
    )
)

;; Release allocated resources
(define-public (release-resource (resource-id uint))
    (let
        (
            (caller tx-sender)
            (allocation-data (unwrap! 
                (map-get? dapp-allocations {dapp: caller, resource-id: resource-id})
                err-resource-not-found))
            (resource-data (unwrap! (map-get? resources resource-id) err-resource-not-found))
        )
        ;; Update resource allocation
        (map-set resources resource-id
            (merge resource-data {
                allocated: (- (get allocated resource-data) (get allocated-amount allocation-data))
            })
        )
        
        ;; Remove allocation record
        (map-delete dapp-allocations {dapp: caller, resource-id: resource-id})
        
        (ok true)
    )
)

;; Update validator reputation (only contract owner)
(define-public (update-reputation (validator principal) (new-score uint))
    (let
        (
            (validator-data (unwrap! (map-get? validators validator) err-validator-not-found))
        )
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        
        (map-set validators validator
            (merge validator-data {
                reputation-score: new-score
            })
        )
        
        (ok true)
    )
)

;; Withdraw stake (deactivate validator)
(define-public (withdraw-stake)
    (let
        (
            (caller tx-sender)
            (validator-data (unwrap! (map-get? validators caller) err-validator-not-found))
            (stake-amount (get stake-amount validator-data))
        )
        ;; Deactivate validator
        (map-set validators caller
            (merge validator-data {
                active: false
            })
        )
        
        ;; Return stake
        (try! (as-contract (stx-transfer? stake-amount tx-sender caller)))
        
        ;; Update totals
        (var-set total-staked (- (var-get total-staked) stake-amount))
        (var-set total-validators (- (var-get total-validators) u1))
        
        (ok true)
    )
)

;; Update protocol fee (only owner)
(define-public (set-protocol-fee (new-fee uint))
    (begin
        (asserts! (is-eq tx-sender contract-owner) err-owner-only)
        (asserts! (<= new-fee u1000) err-invalid-amount) ;; Max 10%
        (var-set protocol-fee-percentage new-fee)
        (ok true)
    )
)