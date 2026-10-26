# Changelog

## 0.2.0

- **Breaking security change:** custom stores must be absent or empty before
  entry. Retained stores are for inspection and cannot be reopened; rejecting
  all persisted entries also excludes hardlinks to host files.
- Reject `File.copy`, `File.rename`, `Directory.rename`, and `Link.rename`,
  including synchronous variants and outside-scope handles, before mutation.
  Async calls fail without first performing the native operation.
- Guard handles returned through ordinary constructors and derived entities;
  classify aliases into custom stores before allowing link operations.
- Reject temporary-directory creation on overlay handles and changes to
  `Directory.current`; guard current-directory and system-temp handles.
- Preserve file and directory deletions across new logical handles, terminate
  parent traversal at the store root, and support nested overlays with separate
  stores.
- Document raw-path constructors as an `IOOverrides` bypass.
- **Breaking security change:** virtualized `Link` handles are no longer
  supported and throw `FileSystemException`, including read-only operations.
  Outside selected paths, supported link operations affect the host filesystem.
- Reject symbolic links at the store root and throughout persisted store data,
  including shadow-index files. Recheck mapped and direct store paths before
  returning guarded handles or resolving metadata, including cached lookups.
- Canonicalize ancestors above the storage root so system temp aliases such as
  macOS `/var` work without accepting links inside the store.
- Document the overlay's security boundary and update examples for link removal.
- Use `path: ^1.9.0` to retain Dart 3.3 compatibility.

## 0.1.0

- Initial release.
- Adds a virtual filesystem overlay implemented using `IOOverrides`.
- Supports write redirection with host filesystem materialization.
- Includes coverage for `path` and `dcli` package usage patterns.
- Includes file-link and watch behavior tests.
- Adds benchmark harness with historical JSON result comparisons.
