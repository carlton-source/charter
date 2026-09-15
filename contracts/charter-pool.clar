;; charter-pool
;; ---------------------------------------------------------------------------
;; Split-leg membership for a PoX-5 protocol bond.
;;
;; A protocol bond is a dual-asset, 12-cycle commitment: sBTC (the yield-bearing
;; leg) paired with locked STX. Under PoX-5 the STX leg "gates participation and
;; signing weight but earns nothing while paired" -- it is ballast. Today that
;; means only holders of BOTH assets can open a bond.
;;
;; This pool lets the two legs come from different people:
;;   - ballast lenders quote a price, in bps of the bond's yield, to supply STX
;;   - charterers commit sBTC and pay that price out of yield, never principal
;;
;; PoX-5 sees only the pool contract as the staker; every member-level record
;; lives here, because "PoX-5 has no pool, envelope, or pro-rata mechanism of
;; its own."
;;
;; Two properties are structural, not incidental:
;;   1. No oracle. The only price-like input, stx-value-ratio, is a constant
;;      the protocol publishes per period. The ballast price comes from the
;;      lenders' own quotes.
;;   2. No liquidation. The fee is a share of arriving yield, so no obligation
;;      can ever exceed receipts and no position can go underwater.
;;
;; Clarity 4. Every outflow from the pool goes through as-contract? with an
;; explicit allowance, so a transfer that tried to move more than the amount
;; being claimed reverts inside the contract rather than relying on the
;; caller to attach a post-condition.
;; ---------------------------------------------------------------------------

(use-trait sip-010 .sip-010-trait.sip-010-trait)

;; --- errors ---------------------------------------------------------------
(define-constant ERR_NOT_OPERATOR      (err u200))
(define-constant ERR_WRONG_STATE       (err u201))
(define-constant ERR_ZERO_AMOUNT       (err u202))
(define-constant ERR_NO_QUOTE          (err u203))
(define-constant ERR_QUOTE_ORDERING    (err u204))
(define-constant ERR_UNDERFILLED       (err u205))
(define-constant ERR_NO_POSITION       (err u206))
(define-constant ERR_NOTHING_CLAIMABLE  (err u207))
(define-constant ERR_UNEXPECTED_TOKEN  (err u208))
(define-constant ERR_RATE_TOO_HIGH     (err u209))
(define-constant ERR_ALREADY_FILLED    (err u210))
(define-constant ERR_ALLOWANCE_VIOLATED (err u211))

;; --- states ---------------------------------------------------------------
(define-constant STATE_OPEN    u0) ;; accepting quotes and charters
(define-constant STATE_FORMED  u1) ;; ratio met, bond registered, yield flowing
(define-constant STATE_MATURED u2) ;; term over, principal releasable

(define-constant BPS u10000)
;; Fixed-point scale for the per-unit yield accumulators.
(define-constant SCALE u1000000000000)

;; --- configuration --------------------------------------------------------
(define-data-var operator principal tx-sender)

;; The sBTC contract this pool settles in. Checked on every token call so a
;; caller cannot substitute a token of their own.
(define-data-var sbtc-token principal .mock-sbtc)

;; Published by the Endowment per bond period, roughly 7 days before Day 0.
;;
;; stx-value-ratio is the STX/BTC price the period is settled at: uSTX per 100
;; sats. It is NOT the amount to lock. minimum-stx-ratio-bps is the collateral
;; floor applied on top of it -- 500 bps, the "5%" the docs refer to.
;;
;; Verified against every registration in mainnet bond 1, the Genesis Bond
;; (stx-value-ratio 310237, minimum-stx-ratio 500): individual registrants
;; lock exactly this floor, pool contracts a few uSTX above it from rounding
;; each member up. See scripts/verify-mainnet-parameters.sh.
(define-data-var stx-value-ratio uint u0)
(define-data-var minimum-stx-ratio-bps uint u500)


;; --- bond state -----------------------------------------------------------
(define-data-var state uint STATE_OPEN)
(define-data-var total-sats uint u0)        ;; charter leg committed
(define-data-var filled-ustx uint u0)       ;; ballast leg locked
(define-data-var clearing-rate-bps uint u0) ;; uniform price paid to ballast
(define-data-var total-distributed uint u0)

;; Cumulative yield per unit of committed capital, scaled by SCALE.
(define-data-var acc-ballast-per-ustx uint u0)
(define-data-var acc-charter-per-sat uint u0)

;; --- members --------------------------------------------------------------
(define-data-var next-quote-id uint u0)

(define-map quotes
  uint
  { lender: principal, ustx: uint, rate-bps: uint, filled: bool })

(define-map ballast-positions
  principal
  { ustx: uint, yield-claimed: uint, principal-claimed: bool })

(define-map charter-positions
  principal
  { sats: uint, yield-claimed: uint, principal-claimed: bool })

;; --- read-only ------------------------------------------------------------

(define-read-only (get-state) (var-get state))

(define-read-only (get-bond)
  {
    state: (var-get state),
    total-sats: (var-get total-sats),
    required-ustx: (required-ustx-for (var-get total-sats)),
    filled-ustx: (var-get filled-ustx),
    clearing-rate-bps: (var-get clearing-rate-bps),
    total-distributed: (var-get total-distributed),
    stx-value-ratio: (var-get stx-value-ratio),
    minimum-stx-ratio-bps: (var-get minimum-stx-ratio-bps)
  })

(define-read-only (get-quote (id uint)) (map-get? quotes id))
(define-read-only (get-ballast-position (who principal)) (map-get? ballast-positions who))
(define-read-only (get-charter-position (who principal)) (map-get? charter-positions who))

;; uSTX that must be locked against a given sats commitment. This is pox-5's
;; own min-ustx-for-sats-amount, floor division included, so a bond sized here
;; is never short of the minimum pox-5 will accept.
;;
;; There is deliberately no option to lock more. pox-5 orders payouts between
;; bonds by each bond's admin-set stx-value-ratio, so extra STX inside a bond
;; buys no payment priority. It would only be ballast earning nothing.
(define-read-only (required-ustx-for (sats uint))
  (/ (* (/ (* (var-get stx-value-ratio) sats) u100)
        (var-get minimum-stx-ratio-bps))
     BPS))

(define-read-only (get-ballast-claimable (who principal))
  (match (map-get? ballast-positions who) pos
    (- (/ (* (get ustx pos) (var-get acc-ballast-per-ustx)) SCALE) (get yield-claimed pos))
    u0))

(define-read-only (get-charter-claimable (who principal))
  (match (map-get? charter-positions who) pos
    (- (/ (* (get sats pos) (var-get acc-charter-per-sat)) SCALE) (get yield-claimed pos))
    u0))

;; --- configuration (operator) ---------------------------------------------

(define-public (set-period-parameters (ratio uint) (min-ratio-bps uint))
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) ERR_NOT_OPERATOR)
    (asserts! (is-eq (var-get state) STATE_OPEN) ERR_WRONG_STATE)
    (asserts! (> ratio u0) ERR_ZERO_AMOUNT)
    (asserts! (> min-ratio-bps u0) ERR_ZERO_AMOUNT)
    (var-set stx-value-ratio ratio)
    (var-set minimum-stx-ratio-bps min-ratio-bps)
    (ok true)))

;; Point the pool at the sBTC contract it settles in: the mock in the local
;; test build, the canonical sbtc-token on testnet and mainnet.
(define-public (set-sbtc-token (token principal))
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) ERR_NOT_OPERATOR)
    (asserts! (is-eq (var-get state) STATE_OPEN) ERR_WRONG_STATE)
    (var-set sbtc-token token)
    (ok true)))

(define-public (transfer-operator (new-operator principal))
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) ERR_NOT_OPERATOR)
    (var-set operator new-operator)
    (ok true)))

;; --- ballast leg (STX only) -----------------------------------------------

;; A lender locks STX and names the share of bond yield, in bps, they require
;; in return. They never touch sBTC and take no BTC price exposure.
(define-public (submit-ballast-quote (ustx uint) (rate-bps uint))
  (let ((id (var-get next-quote-id)))
    (asserts! (is-eq (var-get state) STATE_OPEN) ERR_WRONG_STATE)
    (asserts! (> ustx u0) ERR_ZERO_AMOUNT)
    (asserts! (< rate-bps BPS) ERR_RATE_TOO_HIGH)
    (try! (stx-transfer? ustx tx-sender current-contract))
    (map-set quotes id { lender: tx-sender, ustx: ustx, rate-bps: rate-bps, filled: false })
    (var-set next-quote-id (+ id u1))
    (ok id)))

;; --- charter leg (sBTC only) ----------------------------------------------

;; A Bitcoin holder commits sBTC. They never buy or hold STX.
(define-public (submit-charter (token <sip-010>) (sats uint))
  (let ((existing (default-to { sats: u0, yield-claimed: u0, principal-claimed: false }
                              (map-get? charter-positions tx-sender))))
    (asserts! (is-eq (var-get state) STATE_OPEN) ERR_WRONG_STATE)
    (asserts! (> sats u0) ERR_ZERO_AMOUNT)
    (asserts! (is-eq (contract-of token) (var-get sbtc-token)) ERR_UNEXPECTED_TOKEN)
    (try! (contract-call? token transfer sats tx-sender current-contract none))
    (map-set charter-positions tx-sender (merge existing { sats: (+ (get sats existing) sats) }))
    (var-set total-sats (+ (var-get total-sats) sats))
    (ok true)))

;; --- formation ------------------------------------------------------------

;; Fills quotes cheapest-first. The caller supplies the order and the contract
;; verifies it is non-decreasing in rate, the same pattern PoX-5 uses for bond
;; payment ordering. Everyone filled is paid the clearing rate -- the highest
;; accepted quote -- so a lender never loses by quoting honestly.
(define-private (fill-one (id uint) (acc { prev-rate: uint, filled: uint, clearing: uint, required: uint, valid: bool }))
  (if (not (get valid acc))
    acc
    (match (map-get? quotes id) q
      (if (or (< (get rate-bps q) (get prev-rate acc)) (get filled q))
        (merge acc { valid: false })
        (if (>= (get filled acc) (get required acc))
          ;; requirement already met; leave this quote unfilled
          (merge acc { prev-rate: (get rate-bps q) })
          (begin
            (map-set quotes id (merge q { filled: true }))
            (map-set ballast-positions (get lender q)
              { ustx: (+ (get ustx q)
                         (get ustx (default-to { ustx: u0, yield-claimed: u0, principal-claimed: false }
                                               (map-get? ballast-positions (get lender q)))))
                , yield-claimed: u0
                , principal-claimed: false })
            (merge acc { prev-rate: (get rate-bps q)
                       , filled: (+ (get filled acc) (get ustx q))
                       , clearing: (get rate-bps q) }))))
      (merge acc { valid: false }))))

(define-public (form-bond (quote-ids (list 50 uint)))
  (let ((required (required-ustx-for (var-get total-sats)))
        (result (fold fill-one quote-ids
                  { prev-rate: u0, filled: u0, clearing: u0, required: (required-ustx-for (var-get total-sats)), valid: true })))
    (asserts! (is-eq tx-sender (var-get operator)) ERR_NOT_OPERATOR)
    (asserts! (is-eq (var-get state) STATE_OPEN) ERR_WRONG_STATE)
    (asserts! (> (var-get total-sats) u0) ERR_ZERO_AMOUNT)
    (asserts! (get valid result) ERR_QUOTE_ORDERING)
    (asserts! (>= (get filled result) required) ERR_UNDERFILLED)
    (var-set filled-ustx (get filled result))
    (var-set clearing-rate-bps (get clearing result))
    (var-set state STATE_FORMED)
    (ok { filled-ustx: (get filled result), clearing-rate-bps: (get clearing result), required-ustx: required })))

;; --- yield ----------------------------------------------------------------

;; One protocol distribution arriving for this bond. Distributions run roughly
;; 50 times a year, so a correct split is observable within days of formation
;; -- the bond's own 12-cycle term is far longer than any grant window.
;;
;; The ballast fee is a share of what actually arrives. If a shortfall means
;; nothing arrives, nothing is owed: no debt accrues, so no position can ever
;; require liquidation.
(define-public (receive-distribution (token <sip-010>) (sats uint))
  (let ((ballast-cut (/ (* sats (var-get clearing-rate-bps)) BPS)))
    (asserts! (is-eq (var-get state) STATE_FORMED) ERR_WRONG_STATE)
    (asserts! (> sats u0) ERR_ZERO_AMOUNT)
    (asserts! (is-eq (contract-of token) (var-get sbtc-token)) ERR_UNEXPECTED_TOKEN)
    (try! (contract-call? token transfer sats tx-sender current-contract none))
    (var-set acc-ballast-per-ustx
      (+ (var-get acc-ballast-per-ustx) (/ (* ballast-cut SCALE) (var-get filled-ustx))))
    (var-set acc-charter-per-sat
      (+ (var-get acc-charter-per-sat) (/ (* (- sats ballast-cut) SCALE) (var-get total-sats))))
    (var-set total-distributed (+ (var-get total-distributed) sats))
    (ok { to-ballast: ballast-cut, to-charter: (- sats ballast-cut) })))

;; --- claims ---------------------------------------------------------------

(define-public (claim-ballast-yield (token <sip-010>))
  (let ((who tx-sender)
        (amount (get-ballast-claimable tx-sender))
        (pos (unwrap! (map-get? ballast-positions tx-sender) ERR_NO_POSITION)))
    (asserts! (is-eq (contract-of token) (var-get sbtc-token)) ERR_UNEXPECTED_TOKEN)
    (asserts! (> amount u0) ERR_NOTHING_CLAIMABLE)
    (map-set ballast-positions who (merge pos { yield-claimed: (+ (get yield-claimed pos) amount) }))
    (unwrap! (as-contract? ((with-ft (contract-of token) "sbtc-token" amount))
               (try! (contract-call? token transfer amount tx-sender who none)))
             ERR_ALLOWANCE_VIOLATED)
    (ok amount)))

(define-public (claim-charter-yield (token <sip-010>))
  (let ((who tx-sender)
        (amount (get-charter-claimable tx-sender))
        (pos (unwrap! (map-get? charter-positions tx-sender) ERR_NO_POSITION)))
    (asserts! (is-eq (contract-of token) (var-get sbtc-token)) ERR_UNEXPECTED_TOKEN)
    (asserts! (> amount u0) ERR_NOTHING_CLAIMABLE)
    (map-set charter-positions who (merge pos { yield-claimed: (+ (get yield-claimed pos) amount) }))
    (unwrap! (as-contract? ((with-ft (contract-of token) "sbtc-token" amount))
               (try! (contract-call? token transfer amount tx-sender who none)))
             ERR_ALLOWANCE_VIOLATED)
    (ok amount)))

;; Withdraw an unfilled quote's STX. Available while the bond is still open.
(define-public (withdraw-unfilled-quote (id uint))
  (let ((q (unwrap! (map-get? quotes id) ERR_NO_QUOTE))
        (who tx-sender))
    (asserts! (is-eq (var-get state) STATE_OPEN) ERR_WRONG_STATE)
    (asserts! (is-eq (get lender q) who) ERR_NO_POSITION)
    (asserts! (not (get filled q)) ERR_ALREADY_FILLED)
    (map-delete quotes id)
    (unwrap! (as-contract? ((with-stx (get ustx q)))
               (try! (stx-transfer? (get ustx q) tx-sender who)))
             ERR_ALLOWANCE_VIOLATED)
    (ok (get ustx q))))

;; --- maturity -------------------------------------------------------------

(define-public (mature-bond)
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) ERR_NOT_OPERATOR)
    (asserts! (is-eq (var-get state) STATE_FORMED) ERR_WRONG_STATE)
    (var-set state STATE_MATURED)
    (ok true)))

(define-public (claim-ballast-principal)
  (let ((who tx-sender)
        (pos (unwrap! (map-get? ballast-positions tx-sender) ERR_NO_POSITION)))
    (asserts! (is-eq (var-get state) STATE_MATURED) ERR_WRONG_STATE)
    (asserts! (not (get principal-claimed pos)) ERR_NOTHING_CLAIMABLE)
    (map-set ballast-positions who (merge pos { principal-claimed: true }))
    (unwrap! (as-contract? ((with-stx (get ustx pos)))
               (try! (stx-transfer? (get ustx pos) tx-sender who)))
             ERR_ALLOWANCE_VIOLATED)
    (ok (get ustx pos))))

(define-public (claim-charter-principal (token <sip-010>))
  (let ((who tx-sender)
        (pos (unwrap! (map-get? charter-positions tx-sender) ERR_NO_POSITION)))
    (asserts! (is-eq (var-get state) STATE_MATURED) ERR_WRONG_STATE)
    (asserts! (is-eq (contract-of token) (var-get sbtc-token)) ERR_UNEXPECTED_TOKEN)
    (asserts! (not (get principal-claimed pos)) ERR_NOTHING_CLAIMABLE)
    (map-set charter-positions who (merge pos { principal-claimed: true }))
    (unwrap! (as-contract? ((with-ft (contract-of token) "sbtc-token" (get sats pos)))
               (try! (contract-call? token transfer (get sats pos) tx-sender who none)))
             ERR_ALLOWANCE_VIOLATED)
    (ok (get sats pos))))
