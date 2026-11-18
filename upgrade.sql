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
