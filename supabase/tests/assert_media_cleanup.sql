-- Media cleanup assertions (migration 010 on top of 009). Run after assert_part1.sql or on a fresh DB.
\set ON_ERROR_STOP on
begin;
create function pg_temp.must(ok boolean, msg text) returns void language plpgsql as $$ begin if ok is not true then raise exception 'ASSERT FAILED: %', msg; end if; end $$;

select pg_temp.must(not has_function_privilege('anon', 'public.media_take_orphans(int)', 'execute'), 'anon can read the cleanup queue');
select pg_temp.must(not has_function_privilege('authenticated', 'public.media_forget_orphans(text[])', 'execute'), 'client can clear the cleanup queue');
select pg_temp.must(not has_table_privilege('authenticated', 'public.media_orphans', 'select'), 'client can read media_orphans');

insert into auth.users (id, email, email_confirmed_at) values
  ('00000000-0000-0000-0000-0000000000d1', 'u@t.id', now()), ('00000000-0000-0000-0000-0000000000d2', 'o@t.id', now());
insert into public.user_roles (user_id, role) values ('00000000-0000-0000-0000-0000000000d2', 'owner');

create function pg_temp.make_note(tag text, media jsonb) returns uuid language plpgsql as $$
declare ref text; nid uuid;
begin
  ref := (public.create_publication_order(p_user_id => '00000000-0000-0000-0000-0000000000d1', p_author_name => 'U', p_body => tag,
            p_color => 'yellow', p_social_link => null, p_show_amount => true, p_amount => '5000', p_decorations => '{}'::text[],
            p_use_credit => false, p_guest_token_hash => repeat('a', 64), p_media => media))->>'order_ref';
  select n.id into nid from public.notes n join public.orders o on o.id = n.order_id where o.order_ref = ref;
  return nid;
end $$;

select pg_temp.make_note('one', '[{"path":"00000000-0000-0000-0000-0000000000d1/a1.jpg","kind":"image"},{"path":"00000000-0000-0000-0000-0000000000d1/a2.mp4","kind":"video"}]') as n1 \gset
select pg_temp.make_note('two', '[{"path":"00000000-0000-0000-0000-0000000000d1/b1.png","kind":"image"}]') as n2 \gset
select pg_temp.make_note('three', '[{"path":"00000000-0000-0000-0000-0000000000d1/c1.gif","kind":"image"}]') as n3 \gset
select pg_temp.make_note('four', null) as n4 \gset

-- live notes keep their files
update public.notes set status = 'published' where id = :'n1';
select pg_temp.must((select count(*) from public.media_orphans) = 0, 'publishing must not queue files');
select pg_temp.must(jsonb_array_length((select media from public.notes where id = :'n1')) = 2, 'published note keeps media');

-- removal queues the files and detaches them
update public.notes set status = 'removed' where id = :'n1';
select pg_temp.must((select count(*) from public.media_orphans) = 2, 'removed note queues both files');
select pg_temp.must((select media from public.notes where id = :'n1') is null, 'removed note no longer lists media');
-- restoring does not bring the files back and does not re-queue
update public.notes set status = 'published' where id = :'n1';
select pg_temp.must((select media from public.notes where id = :'n1') is null and (select count(*) from public.media_orphans) = 2, 'restore is clean');

-- rejected / withdrawn
update public.notes set status = 'rejected' where id = :'n2';
update public.notes set status = 'withdrawn' where id = :'n3';
select pg_temp.must((select count(*) from public.media_orphans) = 4, 'rejected and withdrawn notes queue files');
update public.notes set status = 'removed' where id = :'n4';   -- no media: nothing to queue
select pg_temp.must((select count(*) from public.media_orphans) = 4, 'a note without media queues nothing');

-- owner delete of a live note queues its files
select pg_temp.make_note('five', '[{"path":"00000000-0000-0000-0000-0000000000d1/e1.webp","kind":"image"}]') as n5 \gset
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000d2', true);
select public.owner_delete_record('note', :'n5', 'DELETE');
select pg_temp.must((select count(*) from public.media_orphans) = 5, 'deleted note queues its file');

-- take / forget
select pg_temp.must(cardinality(public.media_take_orphans(3)) = 3, 'take respects the limit');
select public.media_forget_orphans(public.media_take_orphans(100));
select pg_temp.must((select count(*) from public.media_orphans) = 0, 'forget empties the queue');
rollback;
\echo ALL MEDIA CLEANUP ASSERTIONS PASSED
