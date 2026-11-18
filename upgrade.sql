-- Customer loyalty tiers and invoice management upgrade
create table if not exists public.mt_tiers (
 id bigserial primary key, name text not null unique, min_amount bigint not null default 0 check(min_amount>=0),
 color text not null default '#00f0d0', icon text not null default '⭐', sort_order integer not null default 0,
 active boolean not null default true, created_at timestamptz not null default now()
);
insert into public.mt_tiers(name,min_amount,color,icon,sort_order)
select 'عادی',0,'#9ca3af','🛍️',0 where not exists(select 1 from public.mt_tiers);
insert into public.mt_tiers(name,min_amount,color,icon,sort_order)
select 'نقره‌ای',5000000,'#b9c4d0','🥈',1 where not exists(select 1 from public.mt_tiers where name='نقره‌ای');
insert into public.mt_tiers(name,min_amount,color,icon,sort_order)
select 'طلایی',20000000,'#ffd700','🥇',2 where not exists(select 1 from public.mt_tiers where name='طلایی');
insert into public.mt_tiers(name,min_amount,color,icon,sort_order)
select 'الماسی',50000000,'#4deaff','💎',3 where not exists(select 1 from public.mt_tiers where name='الماسی');

create table if not exists public.mt_sales_invoices (
 id bigserial primary key, customer_id bigint not null references public.mt_users(id),
 order_id bigint not null unique references public.mt_orders(id) on delete cascade,
 customer_name text not null, customer_phone text, inv_date date not null default current_date,
 total bigint not null check(total>0), created_at timestamptz not null default now()
);
alter table public.mt_history add column if not exists invoice_id bigint;
alter table public.mt_history add column if not exists invoice_line_id bigint;
create index if not exists mt_sales_invoices_customer_idx on public.mt_sales_invoices(customer_id);
create index if not exists mt_orders_loyalty_idx on public.mt_orders(customer_id,status);
alter table public.mt_tiers enable row level security;
alter table public.mt_sales_invoices enable row level security;
revoke all on public.mt_tiers from anon,authenticated;
revoke all on public.mt_sales_invoices from anon,authenticated;

create or replace function public.mt_api_tiers(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare u public.mt_users := public.mt_auth(p->>'token','admin'); v_id bigint; v_name text; v_min bigint; v_color text; v_icon text;
begin
 if u.id is null then raise exception 'دسترسی مدیر لازم است'; end if;
 if coalesce(p->>'op','list')='save' then
  v_id:=nullif(p->>'id','')::bigint; v_name:=public.mt_str(p->>'name',60);
  v_min:=greatest(0,coalesce(nullif(p->>'min_amount','')::bigint,0));
  v_color:=coalesce(nullif(p->>'color',''),'#00f0d0'); v_icon:=coalesce(nullif(p->>'icon',''),'⭐');
  if v_name='' then raise exception 'نام رتبه را وارد کنید'; end if;
  if v_color !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'کد رنگ معتبر نیست'; end if;
  if v_id is null then insert into public.mt_tiers(name,min_amount,color,icon,sort_order)
   values(v_name,v_min,v_color,v_icon,coalesce((select max(sort_order)+1 from public.mt_tiers),0)) returning id into v_id;
  else update public.mt_tiers set name=v_name,min_amount=v_min,color=v_color,icon=v_icon where id=v_id;
   if not found then raise exception 'رتبه پیدا نشد'; end if; end if;
 elsif coalesce(p->>'op','list')='delete' then delete from public.mt_tiers where id=(p->>'id')::bigint;
 else return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'min_amount',min_amount,'color',color,'icon',icon,'sort_order',sort_order) order by min_amount,id) from public.mt_tiers where active),'[]'::jsonb); end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'min_amount',min_amount,'color',color,'icon',icon,'sort_order',sort_order) order by min_amount,id) from public.mt_tiers where active),'[]'::jsonb);
end $$;

create or replace function public.mt_api_customer_tier(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer stable set search_path=public,extensions as $$
declare u public.mt_users := public.mt_auth(p->>'token','customer'); v_total bigint; v_current jsonb; v_next jsonb; v_min bigint; v_pct numeric;
begin
 if u.id is null then raise exception 'ابتدا وارد حساب مشتری شوید'; end if;
 select coalesce(sum(total),0)::bigint into v_total from public.mt_orders where customer_id=u.id and status='completed';
 select jsonb_build_object('id',id,'name',name,'min_amount',min_amount,'color',color,'icon',icon) into v_current
 from public.mt_tiers where active and min_amount<=v_total order by min_amount desc,id desc limit 1;
 select jsonb_build_object('id',id,'name',name,'min_amount',min_amount,'color',color,'icon',icon) into v_next
 from public.mt_tiers where active and min_amount>v_total order by min_amount,id limit 1;
 if v_current is null then select jsonb_build_object('id',id,'name',name,'min_amount',min_amount,'color',color,'icon',icon) into v_current from public.mt_tiers where active order by min_amount,id limit 1; end if;
 if v_next is null then v_pct:=100; else
  select min_amount into v_min from public.mt_tiers where active and min_amount>coalesce((v_current->>'min_amount')::bigint,0) order by min_amount limit 1;
  v_pct:=case when coalesce(v_min,0)<=coalesce((v_current->>'min_amount')::bigint,0) then 0 else greatest(0,least(100,((v_total-coalesce((v_current->>'min_amount')::bigint,0))::numeric/(v_min-coalesce((v_current->>'min_amount')::bigint,0)))*100)) end;
 end if;
 return jsonb_build_object('total',v_total,'current',v_current,'next',v_next,'remaining',case when v_next is null then 0 else greatest(0,(v_next->>'min_amount')::bigint-v_total) end,'progress',round(coalesce(v_pct,100),1));
end $$;

create or replace function public.mt_api_sales_invoice_create(p jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare a public.mt_users:=public.mt_auth(p->>'token','admin'); c public.mt_users; v_total bigint; v_date date; v_code text; v_order bigint; v_name text; v_phone text;
begin
 if a.id is null then raise exception 'دسترسی مدیر لازم است'; end if;
 v_name:=public.mt_str(p->>'customer_name',100);
 v_phone:=regexp_replace(public.mt_fd(public.mt_str(p->>'customer_phone',20)),'\s','','g');
 v_total:=nullif(p->>'total','')::bigint;
 if v_name='' or v_total is null or v_total<1 then raise exception 'نام مشتری و مبلغ معتبر الزامی است'; end if;
 v_date:=coalesce(nullif(p->>'date','')::date,current_date);
 if v_phone<>'' then select * into c from public.mt_users where role='customer' and active and phone=v_phone limit 1;
 else select * into c from public.mt_users where role='customer' and active and lower(trim(name))=lower(trim(v_name)) order by id desc limit 1;
  if (select count(*) from public.mt_users where role='customer' and active and lower(trim(name))=lower(trim(v_name)))>1 then raise exception 'چند مشتری با این نام وجود دارد؛ شماره موبایل را وارد کنید'; end if; end if;
 if c.id is null then raise exception 'مشتری پیدا نشد؛ ابتدا مشتری را ثبت‌نام کنید'; end if;
 v_code:='INV-'||upper(substr(encode(gen_random_bytes(5),'hex'),1,10));
 insert into public.mt_orders(code,customer_id,status,total,note,admin_note,cust_name,cust_phone,cust_city,cust_address)
 values(v_code,c.id,'completed',v_total,'ثبت از فاکتور فروش','فاکتور فروش ثبت‌شده توسط مدیر',c.name,c.phone,c.city,c.address) returning id into v_order;
 insert into public.mt_sales_invoices(customer_id,order_id,customer_name,customer_phone,inv_date,total)
 values(c.id,v_order,c.name,c.phone,v_date,v_total);
 return jsonb_build_object('ok',true,'order_id',v_order,'invoice_id',currval('public.mt_sales_invoices_id_seq'),'code',v_code,'total',v_total);
end $$;

create or replace function public.mt_api_invoice_history(p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer stable set search_path=public,extensions as $$
declare a public.mt_users:=public.mt_auth(p->>'token','admin');
begin
 if a.id is null then raise exception 'دسترسی مدیر لازم است'; end if;
 return jsonb_build_object(
 'purchase',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'kind','purchase','seller',i.seller,'date',i.inv_date,'total',i.total,'created_at',i.created_at) order by i.created_at desc) from public.mt_invoices i),'[]'::jsonb),
 'sales',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'kind','sale','customer_id',s.customer_id,'customer_name',s.customer_name,'customer_phone',s.customer_phone,'date',s.inv_date,'total',s.total,'created_at',s.created_at,'order_id',s.order_id) order by s.created_at desc) from public.mt_sales_invoices s),'[]'::jsonb));
end $$;

create or replace function public.mt_api_invoice_delete(p jsonb)
returns jsonb language plpgsql security definer set search_path=public,extensions as $$
declare a public.mt_users:=public.mt_auth(p->>'token','admin'); v_kind text:=p->>'kind'; v_id bigint; v_inv public.mt_invoices; v_s public.mt_sales_invoices; v_row record;
begin
 if a.id is null then raise exception 'دسترسی مدیر لازم است'; end if; v_id:=(p->>'id')::bigint;
 if v_kind='sale' then select * into v_s from public.mt_sales_invoices where id=v_id for update;
  if v_s.id is null then raise exception 'فاکتور فروش پیدا نشد'; end if;
  delete from public.mt_orders where id=v_s.order_id; delete from public.mt_sales_invoices where id=v_id;
  return jsonb_build_object('ok',true,'deleted','sale');
 elsif v_kind='purchase' then select * into v_inv from public.mt_invoices where id=v_id for update;
  if v_inv.id is null then raise exception 'فاکتور خرید پیدا نشد'; end if;
  if (select count(*) from public.mt_invoices where seller is not distinct from v_inv.seller and inv_date is not distinct from v_inv.inv_date)>1 then raise exception 'چند فاکتور از این فروشنده در همین روز وجود دارد؛ حذف برای جلوگیری از اصلاح اشتباه موجودی متوقف شد'; end if;
  for v_row in select product_id,sum(qty)::bigint q from public.mt_history where source='invoice' and seller is not distinct from v_inv.seller and buy_date is not distinct from v_inv.inv_date group by product_id loop
   update public.mt_products set stock=stock-v_row.q where id=v_row.product_id and stock>=v_row.q;
   if not found then raise exception 'موجودی کالا برای برگشت این فاکتور کافی نیست؛ حذف انجام نشد'; end if;
  end loop;
  delete from public.mt_history where source='invoice' and seller is not distinct from v_inv.seller and buy_date is not distinct from v_inv.inv_date;
  delete from public.mt_invoices where id=v_id; return jsonb_build_object('ok',true,'deleted','purchase');
 else raise exception 'نوع فاکتور نامعتبر است'; end if;
end $$;
grant execute on function public.mt_api_tiers(jsonb) to anon,authenticated;
grant execute on function public.mt_api_customer_tier(jsonb) to anon,authenticated;
grant execute on function public.mt_api_sales_invoice_create(jsonb) to anon,authenticated;
grant execute on function public.mt_api_invoice_history(jsonb) to anon,authenticated;
grant execute on function public.mt_api_invoice_delete(jsonb) to anon,authenticated;


-- Correct purchase invoice tracking: every stock-history row must point to its
-- exact invoice header, so deleting one invoice never guesses by seller/date.
CREATE OR REPLACE FUNCTION public.mt_api_invoice_confirm(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions' AS $$
DECLARE
 u public.mt_users := public.mt_auth(p->>'token','admin');
 v_seller text := public.mt_str(p->>'seller',100);
 v_dt text := public.mt_str(p->>'date',20);
 v_date date;
 v_row jsonb;
 v_name text;
 v_qty bigint;
 v_up bigint;
 v_pid bigint;
 v_pr public.mt_products;
 v_raw text;
 v_m numeric;
 v_sell numeric;
 v_total bigint := 0;
 v_invoice_id bigint;
BEGIN
 IF u.id IS NULL THEN RAISE EXCEPTION 'دسترسی مدیر لازم است'; END IF;
 IF jsonb_typeof(p->'rows') IS DISTINCT FROM 'array' OR jsonb_array_length(p->'rows')=0 THEN RAISE EXCEPTION 'ردیفی وجود ندارد'; END IF;
 IF jsonb_array_length(p->'rows')>200 THEN RAISE EXCEPTION 'تعداد ردیف‌ها زیاد است'; END IF;
 IF v_dt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
  BEGIN v_date:=v_dt::date; EXCEPTION WHEN OTHERS THEN v_date:=NULL; END;
 END IF;
 INSERT INTO public.mt_invoices(seller,inv_date,total)
 VALUES(NULLIF(v_seller,''),v_date,0) RETURNING id INTO v_invoice_id;
 FOR v_row IN SELECT value FROM jsonb_array_elements(p->'rows') LOOP
  v_name:=public.mt_str(v_row->>'name',150);
  v_qty:=public.mt_int(v_row->>'qty',1);
  v_up:=public.mt_int(v_row->>'unit_price',1);
  IF v_name='' THEN RAISE EXCEPTION 'نام کالا خالی است'; END IF;
  IF v_qty>1000000 OR v_up>100000000000 THEN RAISE EXCEPTION 'مقدار عددی نامعتبر است'; END IF;
  v_pid:=NULL;
  IF NULLIF(v_row->>'product_id','') IS NOT NULL THEN
   v_pid:=public.mt_int(v_row->>'product_id',1);
   SELECT * INTO v_pr FROM public.mt_products WHERE id=v_pid FOR UPDATE;
   IF v_pr.id IS NULL THEN RAISE EXCEPTION 'محصول انتخاب‌شده وجود ندارد'; END IF;
   UPDATE public.mt_products SET stock=stock+v_qty,buy_price=v_up WHERE id=v_pid;
  ELSE
   v_raw:=regexp_replace(public.mt_fd(coalesce(v_row->>'margin_percent','')),'[,٬\s]','','g');
   v_sell:=v_up;
   IF v_raw ~ '^-?[0-9]{1,6}(\.[0-9]+)?$' THEN
    v_m:=v_raw::numeric;
    v_sell:=round(v_up*(1+v_m/100)/1000)*1000;
    IF v_sell<1 THEN v_sell:=v_up; END IF;
   END IF;
   IF v_sell>100000000000 THEN RAISE EXCEPTION 'قیمت خیلی بزرگ است'; END IF;
   INSERT INTO public.mt_products(name,buy_price,sell_price,stock,active)
   VALUES(v_name,v_up,v_sell::bigint,v_qty,false) RETURNING id INTO v_pid;
  END IF;
  INSERT INTO public.mt_history(product_id,seller,buy_date,qty,unit_price,source,invoice_id)
  VALUES(v_pid,NULLIF(v_seller,''),v_date,v_qty,v_up,'invoice',v_invoice_id);
  v_total:=v_total+v_qty*v_up;
 END LOOP;
 UPDATE public.mt_invoices SET total=v_total WHERE id=v_invoice_id;
 RETURN jsonb_build_object('total',v_total,'invoice_id',v_invoice_id);
END $$;

CREATE OR REPLACE FUNCTION public.mt_api_invoice_delete(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','extensions' AS $$
DECLARE
 a public.mt_users := public.mt_auth(p->>'token','admin');
 v_kind text:=p->>'kind';
 v_id bigint;
 v_inv public.mt_invoices;
 v_s public.mt_sales_invoices;
 v_row record;
 v_count bigint;
BEGIN
 IF a.id IS NULL THEN RAISE EXCEPTION 'دسترسی مدیر لازم است'; END IF;
 v_id:=(p->>'id')::bigint;
 IF v_kind='sale' THEN
  SELECT * INTO v_s FROM public.mt_sales_invoices WHERE id=v_id FOR UPDATE;
  IF v_s.id IS NULL THEN RAISE EXCEPTION 'فاکتور فروش پیدا نشد'; END IF;
  DELETE FROM public.mt_orders WHERE id=v_s.order_id;
  RETURN jsonb_build_object('ok',true,'deleted','sale','customer_id',v_s.customer_id);
 ELSIF v_kind='purchase' THEN
  SELECT * INTO v_inv FROM public.mt_invoices WHERE id=v_id FOR UPDATE;
  IF v_inv.id IS NULL THEN RAISE EXCEPTION 'فاکتور خرید پیدا نشد'; END IF;
  IF EXISTS(SELECT 1 FROM public.mt_history WHERE invoice_id=v_id) THEN
   FOR v_row IN SELECT product_id,SUM(qty)::bigint AS qty
    FROM public.mt_history WHERE invoice_id=v_id GROUP BY product_id LOOP
    UPDATE public.mt_products SET stock=stock-v_row.qty
     WHERE id=v_row.product_id AND stock>=v_row.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'موجودی کالا برای برگشت این فاکتور کافی نیست؛ حذف انجام نشد'; END IF;
   END LOOP;
   DELETE FROM public.mt_history WHERE invoice_id=v_id;
  ELSE
   SELECT count(*) INTO v_count FROM public.mt_invoices
    WHERE seller IS NOT DISTINCT FROM v_inv.seller AND inv_date IS NOT DISTINCT FROM v_inv.inv_date;
   IF v_count<>1 THEN RAISE EXCEPTION 'این فاکتور قدیمی با فاکتور دیگری هم‌فروشنده و هم‌تاریخ است و قابل تفکیک امن نیست'; END IF;
   FOR v_row IN SELECT product_id,SUM(qty)::bigint AS qty FROM public.mt_history
    WHERE source='invoice' AND seller IS NOT DISTINCT FROM v_inv.seller
     AND buy_date IS NOT DISTINCT FROM v_inv.inv_date GROUP BY product_id LOOP
    UPDATE public.mt_products SET stock=stock-v_row.qty
     WHERE id=v_row.product_id AND stock>=v_row.qty;
    IF NOT FOUND THEN RAISE EXCEPTION 'موجودی کالا برای برگشت این فاکتور کافی نیست؛ حذف انجام نشد'; END IF;
   END LOOP;
   DELETE FROM public.mt_history WHERE source='invoice'
    AND seller IS NOT DISTINCT FROM v_inv.seller AND buy_date IS NOT DISTINCT FROM v_inv.inv_date;
  END IF;
  DELETE FROM public.mt_invoices WHERE id=v_id;
  RETURN jsonb_build_object('ok',true,'deleted','purchase');
 ELSE
  RAISE EXCEPTION 'نوع فاکتور نامعتبر است';
 END IF;
END $$;
GRANT EXECUTE ON FUNCTION public.mt_api_invoice_confirm(jsonb) TO anon,authenticated;
GRANT EXECUTE ON FUNCTION public.mt_api_invoice_delete(jsonb) TO anon,authenticated;


-- Account recovery and recovery-phrase support (2026-11-19)
GRANT CREATE ON SCHEMA public TO authenticated;

CREATE OR REPLACE FUNCTION public.mt_api_admin_recover(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions'
AS $function$
DECLARE v_q text:=lower(public.mt_fd(public.mt_str(p->>'username',60))); v_k text; u public.mt_users; sid uuid;
BEGIN
 sid:=public.mt_set_context(p->>'store',NULL);
 IF sid IS NULL THEN RETURN public.mt_err('فروشگاه پیدا نشد؛ لینک فروشگاه را بررسی کنید'); END IF;
 PERFORM public.mt_pass(p->>'next');
 v_k:='arec:'||sid::text||':'||coalesce(nullif(v_q,''),'lookup');
 IF public.mt_locked(v_k) THEN RETURN public.mt_err('تعداد تلاش‌ها زیاد است؛ ۱۵ دقیقه بعد دوباره امتحان کنید'); END IF;
 SELECT * INTO u FROM public.mt_users WHERE store_id=sid AND role='admin' AND active
  AND (v_q='' OR lower(username)=v_q) AND rec_hash IS NOT NULL
  AND rec_hash=crypt(public.mt_rec(p->>'recovery'),rec_hash) LIMIT 1;
 IF u.id IS NULL THEN PERFORM public.mt_fail(v_k); RETURN public.mt_err('نام کاربری یا کلمه بازیابی درست نیست'); END IF;
 UPDATE public.mt_users SET pass_hash=crypt(p->>'next',gen_salt('bf',10)) WHERE id=u.id;
 DELETE FROM public.mt_sessions WHERE user_id=u.id;
 PERFORM public.mt_clear(v_k);
 RETURN jsonb_build_object('ok',true,'username',u.username);
END $function$;

CREATE OR REPLACE FUNCTION public.mt_api_recover(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions'
AS $function$
DECLARE v_q text:=lower(public.mt_fd(public.mt_str(p->>'username',60))); v_k text; u public.mt_users; sid uuid;
BEGIN
 sid:=public.mt_set_context(p->>'store',NULL);
 IF sid IS NULL THEN RETURN public.mt_err('فروشگاه پیدا نشد؛ لینک فروشگاه را بررسی کنید'); END IF;
 PERFORM public.mt_pass(p->>'next');
 v_k:='rec:'||sid::text||':'||coalesce(nullif(v_q,''),'lookup');
 IF public.mt_locked(v_k) THEN RETURN public.mt_err('تعداد تلاش‌ها زیاد است؛ ۱۵ دقیقه بعد دوباره امتحان کنید'); END IF;
 SELECT * INTO u FROM public.mt_users WHERE store_id=sid AND role='customer' AND active
  AND (lower(username)=v_q OR regexp_replace(phone,'[[:space:]]','','g')=regexp_replace(v_q,'[[:space:]]','','g'))
  AND rec_hash IS NOT NULL AND rec_hash=crypt(public.mt_rec(p->>'recovery'),rec_hash) LIMIT 1;
 IF u.id IS NULL THEN PERFORM public.mt_fail(v_k); RETURN public.mt_err('نام کاربری/موبایل یا کلمه بازیابی درست نیست'); END IF;
 UPDATE public.mt_users SET pass_hash=crypt(p->>'next',gen_salt('bf',10)) WHERE id=u.id;
 DELETE FROM public.mt_sessions WHERE user_id=u.id;
 PERFORM public.mt_clear(v_k);
 RETURN jsonb_build_object('ok',true,'username',u.username);
END $function$;

CREATE OR REPLACE FUNCTION public.mt_api_recovery_set(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions'
AS $function$
DECLARE u public.mt_users:=public.mt_auth(p->>'token');
BEGIN
 PERFORM public.mt_set_context(p->>'store',p->>'token');
 IF u.id IS NULL THEN RAISE EXCEPTION 'نشست ورود معتبر نیست؛ دوباره وارد شوید'; END IF;
 IF u.pass_hash<>crypt(coalesce(p->>'password',''),u.pass_hash) THEN RAISE EXCEPTION 'رمز فعلی اشتباه است'; END IF;
 UPDATE public.mt_users SET rec_hash=crypt(public.mt_rec(p->>'recovery'),gen_salt('bf',10)) WHERE id=u.id;
 RETURN jsonb_build_object('ok',true);
END $function$;

CREATE OR REPLACE FUNCTION public.mt_api_register(p jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions'
AS $function$
DECLARE
 v_name text:=public.mt_str(p->>'name',80);
 v_phone text:=regexp_replace(public.mt_fd(public.mt_str(p->>'phone',20)),'[[:space:]]','','g');
 v_city text:=public.mt_str(p->>'city',60); v_addr text:=public.mt_str(p->>'address',400);
 v_user text; v_uid bigint; v_rec text;
BEGIN
 PERFORM public.mt_set_context(p->>'store',p->>'token');
 v_user:=public.mt_username(p->>'username'); v_rec:=public.mt_rec(p->>'recovery');
 IF v_phone !~ '^09[0-9]{9}$' THEN RAISE EXCEPTION 'شماره موبایل باید به شکل 09123456789 باشد'; END IF;
 IF v_name='' OR v_city='' OR v_addr='' THEN RAISE EXCEPTION 'همه اطلاعات الزامی است'; END IF;
 PERFORM public.mt_pass(p->>'password');
 IF EXISTS(SELECT 1 FROM public.mt_users WHERE phone=v_phone) THEN RAISE EXCEPTION 'با این شماره قبلاً ثبت‌نام شده است'; END IF;
 IF EXISTS(SELECT 1 FROM public.mt_users WHERE lower(username)=v_user) THEN RAISE EXCEPTION 'این نام کاربری قبلاً گرفته شده است'; END IF;
 INSERT INTO public.mt_users(role,username,name,phone,city,address,pass_hash,rec_hash)
 VALUES('customer',v_user,v_name,v_phone,v_city,v_addr,crypt(p->>'password',gen_salt('bf',10)),crypt(v_rec,gen_salt('bf',10)))
 RETURNING id INTO v_uid;
 RETURN jsonb_build_object('token',public.mt_issue(v_uid));
EXCEPTION WHEN unique_violation THEN RAISE EXCEPTION 'این نام کاربری یا شماره قبلاً ثبت شده است';
END $function$;

ALTER FUNCTION public.mt_api_admin_recover(jsonb) OWNER TO authenticated;
ALTER FUNCTION public.mt_api_recover(jsonb) OWNER TO authenticated;
ALTER FUNCTION public.mt_api_recovery_set(jsonb) OWNER TO authenticated;
ALTER FUNCTION public.mt_api_register(jsonb) OWNER TO authenticated;
REVOKE CREATE ON SCHEMA public FROM authenticated;
GRANT EXECUTE ON FUNCTION public.mt_api_admin_recover(jsonb), public.mt_api_recover(jsonb),
 public.mt_api_recovery_set(jsonb), public.mt_api_register(jsonb) TO anon,authenticated;
