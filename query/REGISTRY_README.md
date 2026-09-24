# hydronium/query

Optional, client-side server-state cache for Hydronium. Create one client per
mounted browser app; it is never a process-global SSR cache. See the workspace
`docs/ASYNC_DATA.md` for the boundary with resources and route loaders.

Call `client:useQuery(...)` once from a component setup function; the returned
render function reads its reactive accessors. The setup scope owns the observer
and abort/garbage-collection cleanup.
