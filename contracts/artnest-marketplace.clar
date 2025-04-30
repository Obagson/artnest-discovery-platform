;; =================================
;; ArtNest Marketplace Contract
;; =================================
;; This contract manages the ArtNest marketplace platform, enabling artists to
;; mint, list, and sell digital artwork as NFTs. It handles listings, sales,
;; transfers, and royalty distributions, ensuring artists receive fair compensation
;; for their work including ongoing royalties from secondary market sales.
;; =================================

;; =================================
;; Error Constants
;; =================================
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-ALREADY-LISTED (err u102))
(define-constant ERR-INVALID-PRICE (err u103))
(define-constant ERR-NOT-OWNER (err u104))
(define-constant ERR-NOT-ACTIVE (err u105))
(define-constant ERR-INSUFFICIENT-FUNDS (err u106))
(define-constant ERR-INVALID-ROYALTY (err u107))
(define-constant ERR-MODERATED (err u108))
(define-constant ERR-INVALID-TOKEN-ID (err u109))
(define-constant ERR-SELF-TRANSFER (err u110))

;; =================================
;; Contract Configuration Constants
;; =================================
(define-constant CONTRACT-OWNER tx-sender)
(define-constant PLATFORM-FEE-PERCENT u5) ;; 5% platform fee on sales
(define-constant MAX-ROYALTY-PERCENT u30) ;; Max 30% royalty allowed
(define-constant MIN-PRICE u1000) ;; Minimum price in microSTX (0.001 STX)

;; =================================
;; Data Maps & Variables
;; =================================

;; Tracks the last issued token ID
(define-data-var last-token-id uint u0)

;; Stores artwork metadata
(define-map artworks
  { token-id: uint }
  {
    artist: principal,
    title: (string-ascii 100),
    description: (string-utf8 500),
    creation-time: uint,
    ipfs-url: (string-ascii 100),
    royalty-percent: uint,
    moderated: bool
  }
)

;; Tracks token ownership
(define-map token-owners
  { token-id: uint }
  { owner: principal }
)

;; Manages active marketplace listings
(define-map listings
  { token-id: uint }
  {
    seller: principal,
    price: uint,
    listed-at: uint,
    active: bool
  }
)

;; Records sale history for provenance tracking
(define-map sales-history
  { token-id: uint, sale-id: uint }
  {
    seller: principal,
    buyer: principal,
    price: uint,
    time: uint
  }
)

;; Tracks sales counter per token
(define-map token-sales-counter
  { token-id: uint }
  { count: uint }
)

;; Platform moderators
(define-map moderators
  { moderator: principal }
  { active: bool }
)

;; =================================
;; Private Functions
;; =================================

;; Generate a new unique token ID
(define-private (generate-token-id)
  (let ((current-id (var-get last-token-id)))
    (var-set last-token-id (+ current-id u1))
    (+ current-id u1)
  )
)

;; Check if sender is the owner of the token
(define-private (is-owner (token-id uint) (user principal))
  (let ((owner-data (map-get? token-owners { token-id: token-id })))
    (and
      (is-some owner-data)
      (is-eq user (get owner (unwrap! owner-data false)))
    )
  )
)

;; Check if the sender is a platform moderator
(define-private (is-moderator (user principal))
  (let ((moderator-data (map-get? moderators { moderator: user })))
    (and
      (is-some moderator-data)
      (get active (unwrap! moderator-data false))
    )
  )
)

;; Calculate platform fee amount from a sale price
(define-private (calculate-platform-fee (price uint))
  (/ (* price PLATFORM-FEE-PERCENT) u100)
)

;; Calculate royalty amount from a sale price
(define-private (calculate-royalty (price uint) (royalty-percent uint))
  (/ (* price royalty-percent) u100)
)

;; Record a sale in the history
(define-private (record-sale (token-id uint) (seller principal) (buyer principal) (price uint))
  (let (
    (current-count (get-sale-count token-id))
    (new-count (+ current-count u1))
  )
    (map-set token-sales-counter { token-id: token-id } { count: new-count })
    (map-set sales-history 
      { token-id: token-id, sale-id: new-count }
      { seller: seller, buyer: buyer, price: price, time: block-height }
    )
    new-count
  )
)

;; Get the current sale count for a token
(define-private (get-sale-count (token-id uint))
  (default-to u0 (get count (map-get? token-sales-counter { token-id: token-id })))
)

;; Transfer funds for a sale including platform fee and royalties
(define-private (process-sale-payment (token-id uint) (buyer principal) (seller principal) (price uint))
  (let (
    (artwork-data (unwrap! (map-get? artworks { token-id: token-id }) ERR-NOT-FOUND))
    (artist (get artist artwork-data))
    (royalty-percent (get royalty-percent artwork-data))
    (platform-fee (calculate-platform-fee price))
    (artist-royalty (if (is-eq artist seller)
                      u0 ;; No royalty if artist is the seller (primary sale)
                      (calculate-royalty price royalty-percent)))
    (seller-amount (- price (+ platform-fee artist-royalty)))
  )
    ;; Transfer platform fee to contract owner
    (unwrap! (stx-transfer? platform-fee buyer CONTRACT-OWNER) ERR-INSUFFICIENT-FUNDS)
    
    ;; Transfer royalty to artist if it's a secondary sale
    (if (> artist-royalty u0)
      (unwrap! (stx-transfer? artist-royalty buyer artist) ERR-INSUFFICIENT-FUNDS)
      true)
    
    ;; Transfer remaining amount to seller
    (unwrap! (stx-transfer? seller-amount buyer seller) ERR-INSUFFICIENT-FUNDS)
    (ok true)
  )
)

;; =================================
;; Read-Only Functions
;; =================================

;; Get artwork details by token ID
(define-read-only (get-artwork (token-id uint))
  (map-get? artworks { token-id: token-id })
)

;; Get current owner of an artwork
(define-read-only (get-owner (token-id uint))
  (map-get? token-owners { token-id: token-id })
)

;; Get listing information for an artwork
(define-read-only (get-listing (token-id uint))
  (map-get? listings { token-id: token-id })
)

;; Check if an artwork is actively listed
(define-read-only (is-listed (token-id uint))
  (let ((listing (map-get? listings { token-id: token-id })))
    (if (is-some listing)
      (get active (unwrap! listing false))
      false
    )
  )
)

;; Get a specific sale from an artwork's history
(define-read-only (get-sale (token-id uint) (sale-id uint))
  (map-get? sales-history { token-id: token-id, sale-id: sale-id })
)

;; Get total number of sales for an artwork
(define-read-only (get-sales-count (token-id uint))
  (get-sale-count token-id)
)

;; Check if a user is a moderator
(define-read-only (check-moderator (user principal))
  (is-moderator user)
)

;; =================================
;; Public Functions
;; =================================

;; Mint a new artwork NFT
(define-public (mint-artwork 
  (title (string-ascii 100))
  (description (string-utf8 500))
  (ipfs-url (string-ascii 100))
  (royalty-percent uint))
  
  (let (
    (artist tx-sender)
    (token-id (generate-token-id))
  )
    ;; Validate royalty percentage
    (asserts! (<= royalty-percent MAX-ROYALTY-PERCENT) ERR-INVALID-ROYALTY)
    
    ;; Create the artwork
    (map-set artworks
      { token-id: token-id }
      {
        artist: artist,
        title: title,
        description: description,
        creation-time: block-height,
        ipfs-url: ipfs-url,
        royalty-percent: royalty-percent,
        moderated: false
      }
    )
    
    ;; Set initial ownership
    (map-set token-owners
      { token-id: token-id }
      { owner: artist }
    )
    
    ;; Initialize sales counter
    (map-set token-sales-counter
      { token-id: token-id }
      { count: u0 }
    )
    
    (ok token-id)
  )
)

;; List an artwork for sale
(define-public (list-artwork (token-id uint) (price uint))
  (let (
    (artwork (unwrap! (map-get? artworks { token-id: token-id }) ERR-NOT-FOUND))
    (owner-data (unwrap! (map-get? token-owners { token-id: token-id }) ERR-NOT-FOUND))
    (owner (get owner owner-data))
  )
    ;; Verify sender is the owner
    (asserts! (is-eq tx-sender owner) ERR-NOT-OWNER)
    
    ;; Verify artwork is not moderated
    (asserts! (not (get moderated artwork)) ERR-MODERATED)
    
    ;; Validate price
    (asserts! (>= price MIN-PRICE) ERR-INVALID-PRICE)
    
    ;; Create or update listing
    (map-set listings
      { token-id: token-id }
      {
        seller: tx-sender,
        price: price,
        listed-at: block-height,
        active: true
      }
    )
    
    (ok true)
  )
)

;; Cancel a listing
(define-public (cancel-listing (token-id uint))
  (let (
    (listing (unwrap! (map-get? listings { token-id: token-id }) ERR-NOT-FOUND))
    (seller (get seller listing))
  )
    ;; Verify sender is the seller
    (asserts! (is-eq tx-sender seller) ERR-NOT-AUTHORIZED)
    
    ;; Update listing to inactive
    (map-set listings
      { token-id: token-id }
      (merge listing { active: false })
    )
    
    (ok true)
  )
)

;; Purchase an artwork
(define-public (purchase-artwork (token-id uint))
  (let (
    (listing (unwrap! (map-get? listings { token-id: token-id }) ERR-NOT-FOUND))
    (artwork (unwrap! (map-get? artworks { token-id: token-id }) ERR-NOT-FOUND))
    (seller (get seller listing))
    (price (get price listing))
    (active (get active listing))
    (buyer tx-sender)
  )
    ;; Verify listing is active
    (asserts! active ERR-NOT-ACTIVE)
    
    ;; Verify artwork is not moderated
    (asserts! (not (get moderated artwork)) ERR-MODERATED)
    
    ;; Prevent buying from self
    (asserts! (not (is-eq buyer seller)) ERR-SELF-TRANSFER)
    
    ;; Process payment
    (try! (process-sale-payment token-id buyer seller price))
    
    ;; Update ownership
    (map-set token-owners
      { token-id: token-id }
      { owner: buyer }
    )
    
    ;; Deactivate listing
    (map-set listings
      { token-id: token-id }
      (merge listing { active: false })
    )
    
    ;; Record the sale
    (record-sale token-id seller buyer price)
    
    (ok true)
  )
)

;; Update artwork metadata (only title and description can be modified)
(define-public (update-artwork-metadata 
  (token-id uint) 
  (new-title (string-ascii 100))
  (new-description (string-utf8 500)))
  
  (let (
    (artwork (unwrap! (map-get? artworks { token-id: token-id }) ERR-NOT-FOUND))
    (artist (get artist artwork))
  )
    ;; Verify sender is the artist
    (asserts! (is-eq tx-sender artist) ERR-NOT-AUTHORIZED)
    
    ;; Update metadata
    (map-set artworks
      { token-id: token-id }
      (merge artwork 
        { 
          title: new-title, 
          description: new-description
        }
      )
    )
    
    (ok true)
  )
)

;; Transfer artwork to another user (not for sale)
(define-public (transfer-artwork (token-id uint) (recipient principal))
  (let (
    (owner-data (unwrap! (map-get? token-owners { token-id: token-id }) ERR-NOT-FOUND))
    (current-owner (get owner owner-data))
  )
    ;; Verify sender is the owner
    (asserts! (is-eq tx-sender current-owner) ERR-NOT-OWNER)
    
    ;; Prevent transfer to self
    (asserts! (not (is-eq tx-sender recipient)) ERR-SELF-TRANSFER)
    
    ;; Ensure any existing listing is deactivated
    (if (is-listed token-id)
      (map-set listings
        { token-id: token-id }
        (merge (unwrap! (map-get? listings { token-id: token-id }) ERR-NOT-FOUND)
          { active: false }
        )
      )
      true
    )
    
    ;; Update ownership
    (map-set token-owners
      { token-id: token-id }
      { owner: recipient }
    )
    
    (ok true)
  )
)

;; Add a moderator (contract owner only)
(define-public (add-moderator (moderator principal))
  ;; Verify sender is contract owner
  (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
  
  (map-set moderators
    { moderator: moderator }
    { active: true }
  )
  
  (ok true)
)

;; Remove a moderator (contract owner only)
(define-public (remove-moderator (moderator principal))
  ;; Verify sender is contract owner
  (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
  
  (map-set moderators
    { moderator: moderator }
    { active: false }
  )
  
  (ok true)
)

;; Moderate an artwork (moderators only)
(define-public (moderate-artwork (token-id uint) (should-moderate bool))
  (let (
    (artwork (unwrap! (map-get? artworks { token-id: token-id }) ERR-NOT-FOUND))
  )
    ;; Verify sender is a moderator or contract owner
    (asserts! (or (is-eq tx-sender CONTRACT-OWNER) (is-moderator tx-sender)) ERR-NOT-AUTHORIZED)
    
    ;; Update moderation status
    (map-set artworks
      { token-id: token-id }
      (merge artwork { moderated: should-moderate })
    )
    
    ;; If moderating, deactivate any listing
    (if should-moderate
      (if (is-listed token-id)
        (map-set listings
          { token-id: token-id }
          (merge (unwrap! (map-get? listings { token-id: token-id }) ERR-NOT-FOUND)
            { active: false }
          )
        )
        true
      )
      true
    )
    
    (ok true)
  )
)

;; Update royalty percentage (artist only, can only lower never increase)
(define-public (update-royalty (token-id uint) (new-royalty-percent uint))
  (let (
    (artwork (unwrap! (map-get? artworks { token-id: token-id }) ERR-NOT-FOUND))
    (artist (get artist artwork))
    (current-royalty (get royalty-percent artwork))
  )
    ;; Verify sender is the artist
    (asserts! (is-eq tx-sender artist) ERR-NOT-AUTHORIZED)
    
    ;; Verify new royalty is lower than current
    (asserts! (< new-royalty-percent current-royalty) ERR-INVALID-ROYALTY)
    
    ;; Update royalty
    (map-set artworks
      { token-id: token-id }
      (merge artwork { royalty-percent: new-royalty-percent })
    )
    
    (ok true)
  )
)