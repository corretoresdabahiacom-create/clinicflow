-- 1B / migration 6: funções novas não ficam executáveis por PUBLIC/anon (achado do advisor de segurança)
revoke execute on function public.rpc_book_event(uuid, uuid, text, uuid, timestamptz, timestamptz, jsonb, text, uuid) from public, anon;
revoke execute on function public.rpc_cancel_event(uuid, uuid, text, text) from public, anon;
revoke execute on function public.rpc_reschedule_event(uuid, uuid, timestamptz, timestamptz) from public, anon;
revoke execute on function app.has_perm_any(uuid, text) from public, anon;
revoke execute on function app.system_role_permissions() from public, anon;
revoke execute on function app.guard_event_update() from public, anon;
revoke execute on function app.validate_allocation() from public, anon;
