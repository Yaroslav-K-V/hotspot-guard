cat << 'MD_EOF' >> .jules/bolt.md

## 2024-05-27 - N+1 Keychain Lookups
**Learning:** Performing repeated lookups (like `SecItemCopyMatching`) for individual items inside a loop over all items is a classic N+1 query problem, causing significant CPU and I/O overhead.
**Action:** When working with the Keychain or similar storage, fetch all required data at once in a single bulk query (e.g., using `kSecReturnData: true`) if possible, instead of querying item-by-item.
MD_EOF
