-- =====================================================================
-- setup.sql  |  คอร์สแวร์ วิทยาการคำนวณ ป.5 (ว20133)  |  โรงเรียนหนองแสง
-- รันทั้งไฟล์ครั้งเดียวใน Supabase > SQL Editor (รันซ้ำได้ ไม่ลบข้อมูลเดิม)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1) ตาราง
-- ---------------------------------------------------------------------
create table if not exists public.lessons (
  key        text primary key,
  title      text not null,
  sort_order int  not null
);

create table if not exists public.roster (
  student_id text primary key check (student_id ~ '^[0-9]{11}$'),
  full_name  text not null,
  class_room text,
  claimed_by uuid unique references auth.users(id) on delete set null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        text not null check (role in ('student','teacher')),
  student_id  text unique references public.roster(student_id) on update cascade,
  full_name   text not null,
  avatar_path text,
  created_at  timestamptz not null default now()
);

create table if not exists public.progress (
  user_id        uuid not null references public.profiles(id) on delete cascade,
  lesson_key     text not null references public.lessons(key),
  sections_done  int  not null default 0 check (sections_done >= 0),
  sections_total int  not null default 1 check (sections_total > 0),
  completed      boolean not null default false,
  updated_at     timestamptz not null default now(),
  primary key (user_id, lesson_key),
  check (sections_done <= sections_total)
);

create table if not exists public.quiz_questions (
  id            bigint generated always as identity primary key,
  lesson_key    text not null references public.lessons(key),
  q_no          int  not null,
  question      text not null,
  choices       jsonb not null,
  correct_index int  not null,
  explanation   text,
  unique (lesson_key, q_no)
);

create table if not exists public.quiz_attempts (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  lesson_key text not null references public.lessons(key),
  score      int  not null,
  total      int  not null,
  answers    jsonb,
  created_at timestamptz not null default now()
);
create index if not exists quiz_attempts_user_idx on public.quiz_attempts(user_id, lesson_key);

create table if not exists public.assignments (
  id          uuid primary key default gen_random_uuid(),
  lesson_key  text references public.lessons(key),
  title       text not null,
  description text,
  max_score   int  not null default 10 check (max_score > 0),
  due_date    date,
  created_at  timestamptz not null default now()
);

create table if not exists public.submissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.assignments(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  file_path     text not null,
  file_name     text not null,
  note          text,
  submitted_at  timestamptz not null default now(),
  score         int,
  feedback      text,
  graded_by     uuid,
  graded_at     timestamptz,
  unique (assignment_id, user_id)
);

create table if not exists public.media (
  id           uuid primary key default gen_random_uuid(),
  lesson_key   text references public.lessons(key),
  title        text not null,
  description  text,
  storage_path text not null,
  file_name    text not null,
  mime_type    text,
  size_bytes   bigint,
  uploaded_by  uuid,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2) ฟังก์ชันตรวจสิทธิ์ (ใช้ใน RLS)
-- ---------------------------------------------------------------------
create or replace function public.is_teacher() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'teacher')
$$;

create or replace function public.is_student() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'student')
$$;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid())
$$;

-- ---------------------------------------------------------------------
-- 3) Trigger บน auth.users: ผูกบัญชีใหม่กับรายชื่อ
--    - อีเมลรูปแบบ <11 หลัก>@... : ต้องมีในรายชื่อและยังไม่ถูกใช้ มิฉะนั้นสมัครไม่ได้
--    - อีเมลอื่น (ผู้สอน): ข้าม (ไม่ได้สิทธิ์ใด ๆ จนกว่าจะรัน add_teacher)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_sid text;
  v_row public.roster%rowtype;
begin
  if new.email is null or new.email !~ '^[0-9]{11}@' then
    return new;
  end if;
  v_sid := split_part(new.email, '@', 1);

  select * into v_row from public.roster where student_id = v_sid for update;
  if not found then
    raise exception 'รหัสนักเรียนนี้ไม่อยู่ในรายชื่อรายวิชา';
  end if;
  if v_row.claimed_by is not null then
    raise exception 'รหัสนักเรียนนี้ถูกใช้สมัครแล้ว';
  end if;

  update public.roster set claimed_by = new.id, claimed_at = now() where student_id = v_sid;
  insert into public.profiles (id, role, student_id, full_name)
  values (new.id, 'student', v_sid, v_row.full_name);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 4) RPC ฟังก์ชันที่ฝั่งเว็บเรียก
-- ---------------------------------------------------------------------

-- 4.1 ตรวจรหัสก่อนสมัคร (เรียกได้ก่อนล็อกอิน) ไม่คืนชื่อ
create or replace function public.check_student_id(p_id text) returns text
language plpgsql stable security definer set search_path = public as $$
declare r public.roster%rowtype;
begin
  if p_id is null or p_id !~ '^[0-9]{11}$' then return 'invalid'; end if;
  select * into r from public.roster where student_id = p_id;
  if not found then return 'not_found'; end if;
  if r.claimed_by is not null then return 'taken'; end if;
  return 'ok';
end $$;

-- 4.2 ดึงข้อสอบ (ไม่มีเฉลย)
create or replace function public.get_quiz(p_lesson text)
returns table (q_no int, question text, choices jsonb)
language sql stable security definer set search_path = public as $$
  select q.q_no, q.question, q.choices
  from public.quiz_questions q
  where q.lesson_key = p_lesson and public.is_member()
  order by q.q_no
$$;

-- 4.3 ตรวจข้อสอบฝั่งเซิร์ฟเวอร์ + บันทึกคะแนน (เฉพาะนักเรียน)
create or replace function public.submit_quiz(p_lesson text, p_answers jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  q record;
  v_total int := 0;
  v_score int := 0;
  v_res   jsonb := '[]'::jsonb;
  v_ans   int;
  v_ok    boolean;
begin
  if not public.is_member() then raise exception 'ไม่มีสิทธิ์ใช้งาน'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then
    raise exception 'รูปแบบคำตอบไม่ถูกต้อง';
  end if;

  for q in select * from public.quiz_questions where lesson_key = p_lesson order by q_no loop
    v_total := v_total + 1;
    v_ans := case when jsonb_typeof(p_answers -> (v_total - 1)) = 'number'
                  then (p_answers ->> (v_total - 1))::int else -1 end;
    v_ok := (v_ans = q.correct_index);
    if v_ok then v_score := v_score + 1; end if;
    v_res := v_res || jsonb_build_object(
      'q_no', q.q_no, 'correct', v_ok,
      'correct_index', q.correct_index, 'explanation', q.explanation);
  end loop;

  if v_total = 0 then raise exception 'ยังไม่มีข้อสอบในบทนี้'; end if;

  if public.is_student() then
    insert into public.quiz_attempts (user_id, lesson_key, score, total, answers)
    values (auth.uid(), p_lesson, v_score, v_total, p_answers);
  end if;

  return jsonb_build_object('score', v_score, 'total', v_total,
                            'results', v_res, 'saved', public.is_student());
end $$;

-- 4.4 ส่งงาน (นักเรียน) : ส่งซ้ำได้จนกว่าครูจะตรวจ
create or replace function public.submit_assignment(
  p_assignment uuid, p_path text, p_name text, p_note text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_score int;
begin
  if not public.is_student() then raise exception 'เฉพาะนักเรียนเท่านั้นที่ส่งงานได้'; end if;
  if p_path is null or p_path not like (auth.uid()::text || '/%') then
    raise exception 'ที่อยู่ไฟล์ไม่ถูกต้อง';
  end if;
  if not exists (select 1 from public.assignments where id = p_assignment) then
    raise exception 'ไม่พบงานที่มอบหมาย';
  end if;

  select score into v_score from public.submissions
   where assignment_id = p_assignment and user_id = auth.uid();
  if found and v_score is not null then
    raise exception 'ครูตรวจงานนี้แล้ว ส่งใหม่ไม่ได้';
  end if;

  insert into public.submissions (assignment_id, user_id, file_path, file_name, note)
  values (p_assignment, auth.uid(), p_path, p_name, nullif(p_note, ''))
  on conflict (assignment_id, user_id) do update
    set file_path = excluded.file_path, file_name = excluded.file_name,
        note = excluded.note, submitted_at = now()
  returning id into v_id;
  return v_id;
end $$;

-- 4.5 ให้คะแนนงาน (ผู้สอน)
create or replace function public.grade_submission(p_id uuid, p_score int, p_feedback text) returns void
language plpgsql security definer set search_path = public as $$
declare v_max int;
begin
  if not public.is_teacher() then raise exception 'เฉพาะผู้สอน'; end if;
  select a.max_score into v_max
    from public.submissions s join public.assignments a on a.id = s.assignment_id
   where s.id = p_id;
  if not found then raise exception 'ไม่พบงานที่ส่ง'; end if;
  if p_score is null or p_score < 0 or p_score > v_max then
    raise exception 'คะแนนต้องอยู่ระหว่าง 0 ถึง %', v_max;
  end if;
  update public.submissions
     set score = p_score, feedback = nullif(p_feedback, ''),
         graded_by = auth.uid(), graded_at = now()
   where id = p_id;
end $$;

-- 4.6 ผู้สอนรีเซ็ตรหัสผ่านนักเรียน
create or replace function public.reset_student_password(p_student_id text, p_new text) returns void
language plpgsql security definer set search_path = public, auth, extensions as $$
declare v_uid uuid;
begin
  if not public.is_teacher() then raise exception 'เฉพาะผู้สอน'; end if;
  if p_new is null or length(p_new) < 6 then
    raise exception 'รหัสผ่านต้องยาวอย่างน้อย 6 ตัวอักษร';
  end if;
  select claimed_by into v_uid from public.roster where student_id = p_student_id;
  if v_uid is null then raise exception 'นักเรียนคนนี้ยังไม่ได้สมัคร'; end if;
  update auth.users
     set encrypted_password = crypt(p_new, gen_salt('bf')), updated_at = now()
   where id = v_uid;
end $$;

-- 4.7 ผู้สอนปล่อยรหัสนักเรียน (ลบบัญชีและข้อมูลของคนนั้นทั้งหมด เพื่อให้สมัครใหม่ได้)
create or replace function public.release_student(p_student_id text) returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid;
begin
  if not public.is_teacher() then raise exception 'เฉพาะผู้สอน'; end if;
  select claimed_by into v_uid from public.roster where student_id = p_student_id;
  if v_uid is null then raise exception 'รหัสนี้ยังไม่ได้ถูกใช้สมัคร'; end if;
  delete from auth.users where id = v_uid;   -- cascade ไป profiles/progress/คะแนน/งาน
end $$;

-- 4.8 เพิ่มผู้สอน (รันใน SQL Editor เท่านั้น ฝั่งเว็บเรียกไม่ได้)
create or replace function public.add_teacher(p_email text, p_name text) returns text
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise exception 'ไม่พบบัญชีอีเมลนี้ ให้สร้างผู้ใช้ใน Authentication > Users ก่อน';
  end if;
  insert into public.profiles (id, role, full_name) values (v_uid, 'teacher', p_name)
  on conflict (id) do update set role = 'teacher', full_name = excluded.full_name;
  return 'เพิ่มผู้สอนเรียบร้อย: ' || p_email;
end $$;

-- ---------------------------------------------------------------------
-- 5) มุมมองสรุป (ใช้สิทธิ์ของผู้เรียกใช้ ดังนั้นนักเรียนเห็นเฉพาะของตนเอง)
-- ---------------------------------------------------------------------
create or replace view public.v_quiz_best with (security_invoker = true) as
  select user_id, lesson_key,
         max(score) as best_score, max(total) as total,
         count(*) as attempts, max(created_at) as last_at
  from public.quiz_attempts
  group by user_id, lesson_key;

-- ---------------------------------------------------------------------
-- 6) สิทธิ์ระดับตาราง + RLS
-- ---------------------------------------------------------------------
alter table public.lessons        enable row level security;
alter table public.roster         enable row level security;
alter table public.profiles       enable row level security;
alter table public.progress       enable row level security;
alter table public.quiz_questions enable row level security;
alter table public.quiz_attempts  enable row level security;
alter table public.assignments    enable row level security;
alter table public.submissions    enable row level security;
alter table public.media          enable row level security;

revoke all on public.lessons, public.roster, public.profiles, public.progress,
              public.quiz_questions, public.quiz_attempts, public.assignments,
              public.submissions, public.media, public.v_quiz_best
  from anon, authenticated;

grant select on public.lessons        to authenticated;
grant select, insert, update, delete on public.roster to authenticated;
grant select on public.profiles       to authenticated;
grant update (avatar_path) on public.profiles to authenticated;
grant select, insert, update on public.progress to authenticated;
grant select, insert, update, delete on public.quiz_questions to authenticated;
grant select on public.quiz_attempts  to authenticated;
grant select, insert, update, delete on public.assignments to authenticated;
grant select on public.submissions    to authenticated;
grant select, insert, update, delete on public.media to authenticated;
grant select on public.v_quiz_best    to authenticated;

-- lessons
drop policy if exists lessons_read on public.lessons;
create policy lessons_read on public.lessons for select to authenticated using (public.is_member());

-- roster (เฉพาะผู้สอน; นักเรียนไม่ต้องเห็น)
drop policy if exists roster_teacher on public.roster;
create policy roster_teacher on public.roster for all to authenticated
  using (public.is_teacher()) with check (public.is_teacher());

-- profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_teacher());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- progress
drop policy if exists progress_select on public.progress;
create policy progress_select on public.progress for select to authenticated
  using (user_id = auth.uid() or public.is_teacher());
drop policy if exists progress_insert on public.progress;
create policy progress_insert on public.progress for insert to authenticated
  with check (user_id = auth.uid() and public.is_student());
drop policy if exists progress_update on public.progress;
create policy progress_update on public.progress for update to authenticated
  using (user_id = auth.uid() and public.is_student())
  with check (user_id = auth.uid() and public.is_student());

-- quiz_questions (มีเฉลย: ผู้สอนเท่านั้น นักเรียนใช้ get_quiz แทน)
drop policy if exists quizq_teacher on public.quiz_questions;
create policy quizq_teacher on public.quiz_questions for all to authenticated
  using (public.is_teacher()) with check (public.is_teacher());

-- quiz_attempts (เขียนผ่าน submit_quiz เท่านั้น)
drop policy if exists attempts_select on public.quiz_attempts;
create policy attempts_select on public.quiz_attempts for select to authenticated
  using (user_id = auth.uid() or public.is_teacher());

-- assignments
drop policy if exists assignments_read on public.assignments;
create policy assignments_read on public.assignments for select to authenticated
  using (public.is_member());
drop policy if exists assignments_write on public.assignments;
create policy assignments_write on public.assignments for all to authenticated
  using (public.is_teacher()) with check (public.is_teacher());

-- submissions (เขียนผ่าน submit_assignment / grade_submission เท่านั้น)
drop policy if exists submissions_select on public.submissions;
create policy submissions_select on public.submissions for select to authenticated
  using (user_id = auth.uid() or public.is_teacher());

-- media
drop policy if exists media_read on public.media;
create policy media_read on public.media for select to authenticated using (public.is_member());
drop policy if exists media_write on public.media;
create policy media_write on public.media for all to authenticated
  using (public.is_teacher()) with check (public.is_teacher());

-- ---------------------------------------------------------------------
-- 7) สิทธิ์การเรียกฟังก์ชัน
-- ---------------------------------------------------------------------
revoke all on function public.handle_new_user()                         from public, anon, authenticated;
revoke all on function public.add_teacher(text, text)                   from public, anon, authenticated;
revoke all on function public.is_teacher()                              from public, anon;
revoke all on function public.is_student()                              from public, anon;
revoke all on function public.is_member()                               from public, anon;
revoke all on function public.get_quiz(text)                            from public, anon;
revoke all on function public.submit_quiz(text, jsonb)                  from public, anon;
revoke all on function public.submit_assignment(uuid, text, text, text) from public, anon;
revoke all on function public.grade_submission(uuid, int, text)         from public, anon;
revoke all on function public.reset_student_password(text, text)       from public, anon;
revoke all on function public.release_student(text)                     from public, anon;
revoke all on function public.check_student_id(text)                    from public;

grant execute on function public.is_teacher()                              to authenticated;
grant execute on function public.is_student()                              to authenticated;
grant execute on function public.is_member()                               to authenticated;
grant execute on function public.get_quiz(text)                            to authenticated;
grant execute on function public.submit_quiz(text, jsonb)                  to authenticated;
grant execute on function public.submit_assignment(uuid, text, text, text) to authenticated;
grant execute on function public.grade_submission(uuid, int, text)         to authenticated;
grant execute on function public.reset_student_password(text, text)       to authenticated;
grant execute on function public.release_student(text)                     to authenticated;
grant execute on function public.check_student_id(text)                    to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8) Storage: 3 bucket (private ทั้งหมด) + นโยบาย
--    avatars     : รูปโปรไฟล์ เก็บที่ <uid>/ไฟล์
--    submissions : งานที่ส่ง เก็บที่ <uid>/<assignment_id>/ไฟล์
--    media       : สื่อการเรียน ผู้สอนเขียน ทุกคนที่ล็อกอินอ่านได้
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('avatars',     'avatars',     false, 2097152,  array['image/jpeg','image/png','image/webp']),
  ('submissions', 'submissions', false, 10485760, null),
  ('media',       'media',       false, 52428800, array[
      'image/jpeg','image/png','image/webp','image/gif','application/pdf',
      'video/mp4','audio/mpeg','text/plain',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- avatars
drop policy if exists avatars_select on storage.objects;
create policy avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_teacher()));
drop policy if exists avatars_insert on storage.objects;
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_update on storage.objects;
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists avatars_delete on storage.objects;
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

-- submissions (นักเรียนเพิ่มไฟล์ใหม่ได้ แต่แก้/ลบไฟล์เดิมไม่ได้)
drop policy if exists submissions_obj_select on storage.objects;
create policy submissions_obj_select on storage.objects for select to authenticated
  using (bucket_id = 'submissions' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_teacher()));
drop policy if exists submissions_obj_insert on storage.objects;
create policy submissions_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'submissions' and public.is_student()
              and (storage.foldername(name))[1] = auth.uid()::text);

-- media
drop policy if exists media_obj_select on storage.objects;
create policy media_obj_select on storage.objects for select to authenticated
  using (bucket_id = 'media' and public.is_member());
drop policy if exists media_obj_insert on storage.objects;
create policy media_obj_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'media' and public.is_teacher());
drop policy if exists media_obj_update on storage.objects;
create policy media_obj_update on storage.objects for update to authenticated
  using (bucket_id = 'media' and public.is_teacher())
  with check (bucket_id = 'media' and public.is_teacher());
drop policy if exists media_obj_delete on storage.objects;
create policy media_obj_delete on storage.objects for delete to authenticated
  using (bucket_id = 'media' and public.is_teacher());

-- ---------------------------------------------------------------------
-- 9) ข้อมูลเริ่มต้น: บทเรียน ข้อสอบ งานตัวอย่าง
-- ---------------------------------------------------------------------
insert into public.lessons (key, title, sort_order) values
  ('L1', 'ขั้นตอนวิธีและการแก้ปัญหา', 1),
  ('L2', 'ผังงานและโครงสร้างการทำงาน', 2),
  ('L3', 'ข้อมูลและการนำเสนอข้อมูล', 3),
  ('L4', 'ความปลอดภัยและความรับผิดชอบเมื่อใช้เทคโนโลยี', 4)
on conflict (key) do update set title = excluded.title, sort_order = excluded.sort_order;

insert into public.quiz_questions (lesson_key, q_no, question, choices, correct_index, explanation) values
('L1',1,'ขั้นตอนวิธี (Algorithm) หมายถึงข้อใด',
  '["ชื่อโปรแกรมคอมพิวเตอร์","ลำดับขั้นตอนการทำงานที่ชัดเจนเพื่อแก้ปัญหา","อุปกรณ์ที่ใช้รับข้อมูลเข้าคอมพิวเตอร์","เกมที่เล่นบนคอมพิวเตอร์"]'::jsonb,1,
  'ขั้นตอนวิธีคือลำดับขั้นตอนที่ชัดเจน ทำตามแล้วแก้ปัญหาหรือทำงานให้สำเร็จได้'),
('L1',2,'ข้อใดไม่ใช่ลักษณะของขั้นตอนวิธีที่ดี',
  '["แต่ละขั้นตอนชัดเจน","เรียงลำดับก่อนหลังได้","ทำไปเรื่อย ๆ โดยไม่ต้องสิ้นสุด","ทำตามแล้วได้ผลลัพธ์ตามที่ต้องการ"]'::jsonb,2,
  'ขั้นตอนวิธีที่ดีต้องมีจุดเริ่มต้นและจุดสิ้นสุด'),
('L1',3,'ขั้นแรกของการแก้ปัญหาคือข้อใด',
  '["ทำความเข้าใจปัญหา","ลงมือทำทันทีโดยไม่คิด","ตรวจสอบผลลัพธ์","เก็บอุปกรณ์"]'::jsonb,0,
  'ต้องเข้าใจปัญหาก่อน จึงวางแผน ลงมือทำ และตรวจสอบ'),
('L1',4,'การเขียนขั้นตอนวิธีด้วยผังงานมีข้อดีอย่างไร',
  '["ทำให้คอมพิวเตอร์ทำงานเร็วขึ้นเสมอ","ทำให้ไม่ต้องคิดแก้ปัญหา","ช่วยให้เห็นลำดับการทำงานเป็นภาพและเข้าใจง่าย","ทำให้โปรแกรมไม่มีข้อผิดพลาด"]'::jsonb,2,
  'ผังงานใช้รูปภาพและลูกศร ช่วยให้เห็นลำดับการทำงานชัดเจน'),
('L1',5,'ข้อใดเป็นตัวอย่างขั้นตอนวิธีในชีวิตประจำวัน',
  '["สูตรทำอาหารที่บอกขั้นตอนตามลำดับ","เพลงที่ชอบ","สีของเสื้อนักเรียน","ชื่อของเพื่อน"]'::jsonb,0,
  'สูตรอาหารบอกลำดับขั้นตอนชัดเจน จึงเป็นขั้นตอนวิธี'),

('L2',1,'สัญลักษณ์รูปวงรีในผังงานใช้แสดงอะไร',
  '["การตัดสินใจ","การทำงานหรือการประมวลผล","จุดเริ่มต้นหรือจุดสิ้นสุด","ทิศทางการทำงาน"]'::jsonb,2,
  'วงรี (หรือสี่เหลี่ยมมุมมน) ใช้แสดงจุดเริ่มต้นและจุดสิ้นสุด'),
('L2',2,'สัญลักษณ์รูปสี่เหลี่ยมขนมเปียกปูนใช้แสดงอะไร',
  '["จุดเริ่มต้น","ทิศทางการทำงาน","การตัดสินใจหรือเงื่อนไข","จุดสิ้นสุด"]'::jsonb,2,
  'สี่เหลี่ยมขนมเปียกปูนใช้ถามเงื่อนไข แล้วแยกเป็นทางเลือก เช่น ใช่/ไม่ใช่'),
('L2',3,'"ถ้าฝนตกให้กางร่ม ถ้าไม่ตกให้เดินตามปกติ" เป็นโครงสร้างแบบใด',
  '["ลำดับ","เงื่อนไข","การทำซ้ำ","การเรียงข้อมูล"]'::jsonb,1,
  'มีการตรวจเงื่อนไข (ฝนตกหรือไม่) แล้วเลือกทำอย่างใดอย่างหนึ่ง'),
('L2',4,'คำสั่ง "ทำซ้ำ 5 ครั้ง: เดินไปข้างหน้า 1 ก้าว" เป็นโครงสร้างแบบใด',
  '["ลำดับ","การทำซ้ำ","เงื่อนไข","การแสดงผล"]'::jsonb,1,
  'คำสั่งเดียวกันถูกทำซ้ำตามจำนวนครั้งที่กำหนด จึงเป็นการทำซ้ำ'),
('L2',5,'ลูกศรในผังงานใช้ทำอะไร',
  '["แสดงจุดเริ่มต้น","เก็บข้อมูล","ตกแต่งผังงานให้สวยงาม","แสดงทิศทางหรือลำดับการทำงาน"]'::jsonb,3,
  'ลูกศรบอกว่าหลังจากขั้นตอนนี้ต้องไปทำขั้นตอนใดต่อ'),

('L3',1,'ข้อมูล (Data) หมายถึงข้อใด',
  '["ข้อเท็จจริงหรือตัวเลขดิบที่ยังไม่ผ่านการประมวลผล","ผลสรุปที่นำไปตัดสินใจได้ทันที","เครื่องคอมพิวเตอร์","โปรแกรมสำหรับวาดภาพ"]'::jsonb,0,
  'ข้อมูลคือข้อเท็จจริงดิบ เช่น ตัวเลข ข้อความ ที่ยังไม่ได้จัดระเบียบ'),
('L3',2,'การถามเพื่อนทุกคนว่าชอบผลไม้ชนิดใด เป็นการรวบรวมข้อมูลด้วยวิธีใด',
  '["การสังเกต","การทดลอง","การสำรวจหรือสอบถาม","การคัดลอกงานเพื่อน"]'::jsonb,2,
  'การถามคำถามกับกลุ่มคนเป็นการสำรวจหรือสอบถาม'),
('L3',3,'ต้องการเปรียบเทียบจำนวนนักเรียนที่ชอบผลไม้แต่ละชนิด ควรนำเสนอด้วยอะไรจึงเหมาะที่สุด',
  '["ภาพถ่ายผลไม้","แผนภูมิแท่ง","เพลงประกอบ","นาฬิกาจับเวลา"]'::jsonb,1,
  'แผนภูมิแท่งช่วยเปรียบเทียบจำนวนของแต่ละกลุ่มได้ง่าย'),
('L3',4,'นักเรียนชอบส้ม 8 คน กล้วย 5 คน มะม่วง 12 คน รวมมีนักเรียนที่ตอบกี่คน',
  '["20","23","25","27"]'::jsonb,2,
  '8 + 5 + 12 = 25 คน'),
('L3',5,'ข้อมูลที่ผ่านการประมวลผลจนมีความหมายและนำไปใช้ประโยชน์ได้ เรียกว่าอะไร',
  '["ข้อมูลดิบ","ไวรัส","รหัสผ่าน","สารสนเทศ"]'::jsonb,3,
  'ข้อมูลที่ผ่านการประมวลผลและมีความหมายเรียกว่าสารสนเทศ'),

('L4',1,'ข้อใดควรเก็บเป็นความลับ ไม่บอกคนแปลกหน้าทางออนไลน์',
  '["สีที่ชอบ","รหัสผ่านและที่อยู่บ้าน","ชื่อวิชาที่เรียน","อาหารจานโปรด"]'::jsonb,1,
  'รหัสผ่านและที่อยู่บ้านเป็นข้อมูลส่วนตัวที่ไม่ควรบอกคนแปลกหน้า'),
('L4',2,'รหัสผ่านที่ดีควรเป็นอย่างไร',
  '["ใช้วันเกิดของตนเอง","ใช้ 123456 เพื่อให้จำง่าย","บอกเพื่อนสนิทได้","ผสมตัวอักษรและตัวเลข ไม่ใช้ชื่อหรือวันเกิดของตนเอง"]'::jsonb,3,
  'รหัสผ่านที่เดายากและไม่เกี่ยวกับข้อมูลส่วนตัว จะปลอดภัยกว่า'),
('L4',3,'มีคนแปลกหน้าในเกมออนไลน์ชวนไปพบตัวต่อตัว ควรทำอย่างไร',
  '["ไม่ตอบรับ และบอกผู้ปกครองหรือครูทันที","ไปพบเพราะอยากได้ไอเทมในเกม","ส่งที่อยู่บ้านให้","เก็บเป็นความลับไม่บอกใคร"]'::jsonb,0,
  'ไม่ควรพบคนแปลกหน้าที่รู้จักทางออนไลน์ และต้องบอกผู้ใหญ่ที่ไว้ใจ'),
('L4',4,'การนำรูปภาพจากอินเทอร์เน็ตมาใช้ในงานของตนเอง ควรทำอย่างไร',
  '["คัดลอกมาแล้วบอกว่าเป็นผลงานของตนเอง","ตรวจสอบสิทธิ์การใช้งานและระบุแหล่งที่มา","ลบชื่อเจ้าของภาพออก","ไม่ต้องทำอะไร เพราะทุกภาพใช้ได้ฟรี"]'::jsonb,1,
  'ผลงานมีเจ้าของ ควรตรวจสอบสิทธิ์การใช้และอ้างอิงแหล่งที่มา'),
('L4',5,'เมื่อพบข้อความที่รังแกเพื่อนทางออนไลน์ ควรทำอย่างไร',
  '["แชร์ต่อให้เพื่อนคนอื่นดู","เขียนข้อความตอบโต้ให้รุนแรงกว่า","ไม่ร่วมแชร์ ไม่ตอบโต้ และแจ้งครูหรือผู้ใหญ่ที่ไว้ใจ","ทำเป็นไม่เห็นและไม่บอกใคร"]'::jsonb,2,
  'ไม่ร่วมรังแกหรือแชร์ต่อ และบอกผู้ใหญ่เพื่อช่วยเหลือเพื่อน')
on conflict (lesson_key, q_no) do update
  set question = excluded.question, choices = excluded.choices,
      correct_index = excluded.correct_index, explanation = excluded.explanation;

insert into public.assignments (id, lesson_key, title, description, max_score) values
  ('a0000000-0000-4000-8000-000000000001', 'L2',
   'วาดผังงานกิจวัตรประจำวัน',
   'เลือกกิจวัตร 1 อย่าง เช่น การแปรงฟัน วาดผังงานที่มีจุดเริ่มต้น ขั้นตอน เงื่อนไข 1 จุด และจุดสิ้นสุด ถ่ายรูปหรือสแกนแล้วส่งเป็นไฟล์ภาพหรือ PDF', 10),
  ('a0000000-0000-4000-8000-000000000002', 'L3',
   'สำรวจข้อมูลของเพื่อน',
   'สำรวจเพื่อนอย่างน้อย 10 คนว่าชอบกีฬาอะไร บันทึกเป็นตารางและวาดแผนภูมิแท่ง แล้วส่งเป็นไฟล์ภาพหรือ PDF', 10)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 10) รายชื่อทดสอบ (ลบก่อนใช้งานจริง! รหัสขึ้นต้น 99 ไม่ใช่รหัสจริง)
--     ลบได้ในหน้าผู้สอน > รายชื่อ หรือรัน:
--     delete from public.roster where student_id like '9900000000%' and claimed_by is null;
-- ---------------------------------------------------------------------
insert into public.roster (student_id, full_name, class_room) values
  ('99000000001', 'นักเรียนทดสอบ 1', 'ทดสอบ'),
  ('99000000002', 'นักเรียนทดสอบ 2', 'ทดสอบ'),
  ('99000000003', 'นักเรียนทดสอบ 3', 'ทดสอบ')
on conflict (student_id) do nothing;

-- ---------------------------------------------------------------------
-- 11) เพิ่มผู้สอน: สร้างผู้ใช้ใน Authentication > Users ก่อน แล้วแก้อีเมลด้านล่าง
--     และรันบรรทัดนี้ (ลบเครื่องหมาย -- หน้าบรรทัด)
-- ---------------------------------------------------------------------
-- select public.add_teacher('ครู@example.com', 'ครูผู้สอน');
