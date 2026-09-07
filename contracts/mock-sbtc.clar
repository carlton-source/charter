;; Minimal SIP-010 token standing in for sbtc-token in the local test build.
;; Eight decimals, same as sBTC. Not for deployment.

(impl-trait .sip-010-trait.sip-010-trait)

(define-fungible-token mock-sbtc)

(define-constant ERR_NOT_OWNER (err u100))

(define-public (transfer (amount uint) (sender principal) (recipient principal) (memo (optional (buff 34))))
  (begin
    (asserts! (is-eq tx-sender sender) ERR_NOT_OWNER)
    (try! (ft-transfer? mock-sbtc amount sender recipient))
    (match memo to-print (print to-print) 0x)
    (ok true)
  )
)

(define-public (mint (amount uint) (recipient principal))
  (ft-mint? mock-sbtc amount recipient)
)

(define-read-only (get-name) (ok "Mock sBTC"))
(define-read-only (get-symbol) (ok "msBTC"))
(define-read-only (get-decimals) (ok u8))
(define-read-only (get-balance (who principal)) (ok (ft-get-balance mock-sbtc who)))
(define-read-only (get-total-supply) (ok (ft-get-supply mock-sbtc)))
(define-read-only (get-token-uri) (ok none))
