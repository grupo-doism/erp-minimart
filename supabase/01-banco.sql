-- =====================================================================
-- ERP MiniMart — banco de dados (Supabase / PostgreSQL)
-- Cole este arquivo inteiro no SQL Editor do Supabase e clique em RUN.
-- Pode rodar de novo sem perder dados (cria só o que ainda não existe
-- e atualiza funções e regras de segurança).
-- =====================================================================
set client_min_messages = warning;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- TABELAS
-- Cada registro do ERP guarda seus campos em "data" (jsonb), no mesmo
-- formato usado pelas telas. "tid" = id do franqueado (tenant).
-- ---------------------------------------------------------------------
create table if not exists public.tenants (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  criado timestamptz not null default now()
);
create table if not exists public.contas (            -- um registro por login
  id uuid primary key references auth.users(id) on delete cascade,
  papel text not null check (papel in ('master_rede','observador','master','colab')),
  tid text references public.tenants(id) on delete cascade,
  ativo boolean not null default true,
  trocar_senha boolean not null default true,
  data jsonb not null default '{}'::jsonb,              -- nome, email, login, telefone, empresa...
  criado timestamptz not null default now()
);
create table if not exists public.logins (            -- CNPJ/CPF -> e-mail (privado)
  doc text primary key,
  email text not null,
  uid uuid not null,
  tid text
);
create table if not exists public.rede_config (id text primary key, data jsonb not null default '{}'::jsonb);
create table if not exists public.rede_diario (
  id text primary key default gen_random_uuid()::text,
  data jsonb not null default '{}'::jsonb,
  criado timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['usuarios','config','lancamentos','fornecedores','agenda','lojas','recorrencias','chamados','diario'] loop
    execute format('create table if not exists public.%I (
        id text primary key default gen_random_uuid()::text,
        tid text not null references public.tenants(id) on delete cascade,
        data jsonb not null default ''{}''::jsonb,
        criado timestamptz not null default now(),
        atualizado timestamptz not null default now())', t);
    execute format('create index if not exists %I on public.%I (tid)', t||'_tid_idx', t);
  end loop;
end $$;
create index if not exists diario_tid_criado_idx on public.diario (tid, criado desc);
create index if not exists chamados_status_idx on public.chamados ((data->>'status'));
create index if not exists contas_tid_idx on public.contas (tid);

-- ---------------------------------------------------------------------
-- QUEM É O USUÁRIO LOGADO (usado pelas regras de segurança)
-- ---------------------------------------------------------------------
create or replace function public.iso_agora() returns text language sql stable as
$$ select to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') $$;

create or replace function public.eu_papel() returns text
language sql stable security definer set search_path = public as $$
  select c.papel from contas c
   where c.id = auth.uid() and c.ativo
     and (c.tid is null or exists (select 1 from tenants t where t.id = c.tid and coalesce((t.data->>'ativo')::boolean, true)))
$$;
create or replace function public.eu_tid() returns text
language sql stable security definer set search_path = public as $$
  select c.tid from contas c where c.id = auth.uid() and c.ativo
$$;
create or replace function public.e_rede() returns boolean language sql stable as
$$ select coalesce(public.eu_papel() in ('master_rede','observador'), false) $$;
create or replace function public.e_master_rede() returns boolean language sql stable as
$$ select coalesce(public.eu_papel() = 'master_rede', false) $$;
create or replace function public.e_membro(t text) returns boolean language sql stable as
$$ select coalesce(public.eu_tid() = t and public.eu_papel() in ('master','colab'), false) $$;
create or replace function public.e_master(t text) returns boolean language sql stable as
$$ select coalesce(public.eu_tid() = t and public.eu_papel() = 'master', false) $$;

-- franqueadora com autorização de edição válida (dada pelo master do franqueado num chamado)
create or replace function public.liberado(t text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.e_master_rede() and exists (
    select 1 from tenants where id = t
      and coalesce(data->'acessoMaster'->>'ate','') <> ''
      and (data->'acessoMaster'->>'ate')::timestamptz > now())
$$;

-- nível do colaborador numa tela: 0 = não acessa, 1 = só leitura, 2 = edita.
-- Contas a pagar/receber ('rec','pag') nunca são liberadas para colaborador.
create or replace function public.nivel(t text, m text) returns int
language sql stable security definer set search_path = public as $$
  select case
    when m in ('rec','pag') then 0
    when public.eu_papel() = 'colab' and public.eu_tid() = t then
      coalesce((select least(coalesce((u.data->'perm'->>m)::int, 0), case when m in ('dash','fluxo','dre') then 1 else 2 end)
                  from usuarios u
                 where u.id = auth.uid()::text and u.tid = t
                   and coalesce((u.data->>'ativo')::boolean, true)), 0)
    else 0 end
$$;
create or replace function public.le(t text, m text) returns boolean language sql stable as
$$ select public.e_master(t) or public.e_rede() or public.nivel(t, m) >= 1 $$;
create or replace function public.edita(t text, m text) returns boolean language sql stable as
$$ select public.e_master(t) or public.liberado(t) or public.nivel(t, m) >= 2 $$;

-- ---------------------------------------------------------------------
-- REGRAS DE SEGURANÇA (Row Level Security)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['tenants','contas','logins','rede_config','rede_diario','usuarios','config','lancamentos','fornecedores','agenda','lojas','recorrencias','chamados','diario'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists sel on public.%I', t);
    execute format('drop policy if exists ins on public.%I', t);
    execute format('drop policy if exists upd on public.%I', t);
    execute format('drop policy if exists del on public.%I', t);
  end loop;
end $$;

-- franqueados: membros veem o próprio; a rede vê todos. Alterações só pelo servidor.
create policy sel on public.tenants for select to authenticated using (public.e_membro(id) or public.e_rede());
-- contas: cada um vê a sua; o master da rede vê todas.
create policy sel on public.contas for select to authenticated using (id = auth.uid() or public.e_master_rede());
-- logins: ninguém lê pelo app (só a função resolver_login).
-- plano de contas da rede: todos leem, só o master da rede grava.
create policy sel on public.rede_config for select to authenticated using (auth.uid() is not null);
create policy ins on public.rede_config for insert to authenticated with check (public.e_master_rede());
create policy upd on public.rede_config for update to authenticated using (public.e_master_rede()) with check (public.e_master_rede());
-- diário da rede: só acrescenta.
create policy sel on public.rede_diario for select to authenticated using (public.e_master_rede());
create policy ins on public.rede_diario for insert to authenticated with check (public.e_rede());
-- usuários do franqueado: leitura; gravação só pelo servidor.
create policy sel on public.usuarios for select to authenticated using (public.e_membro(tid) or public.e_rede());
-- plano de contas próprio do franqueado
create policy sel on public.config for select to authenticated using (public.e_membro(tid) or public.e_rede());
create policy ins on public.config for insert to authenticated with check (public.edita(tid,'config'));
create policy upd on public.config for update to authenticated using (public.edita(tid,'config')) with check (public.edita(tid,'config'));
-- lançamentos e recorrências
create policy sel on public.lancamentos for select to authenticated using (public.le(tid,'lanc') or public.le(tid,'dash') or public.le(tid,'fluxo') or public.le(tid,'dre'));
create policy ins on public.lancamentos for insert to authenticated with check (public.edita(tid,'lanc'));
create policy upd on public.lancamentos for update to authenticated using (public.edita(tid,'lanc')) with check (public.edita(tid,'lanc'));
create policy del on public.lancamentos for delete to authenticated using (public.edita(tid,'lanc'));
create policy sel on public.recorrencias for select to authenticated using (public.le(tid,'lanc') or public.le(tid,'dash') or public.le(tid,'fluxo') or public.le(tid,'dre'));
create policy ins on public.recorrencias for insert to authenticated with check (public.edita(tid,'lanc'));
create policy upd on public.recorrencias for update to authenticated using (public.edita(tid,'lanc')) with check (public.edita(tid,'lanc'));
create policy del on public.recorrencias for delete to authenticated using (public.edita(tid,'lanc'));
-- fornecedores (também criados pelo formulário de lançamento)
create policy sel on public.fornecedores for select to authenticated using (public.le(tid,'forn') or public.le(tid,'lanc'));
create policy ins on public.fornecedores for insert to authenticated with check (public.edita(tid,'forn') or public.edita(tid,'lanc'));
create policy upd on public.fornecedores for update to authenticated using (public.edita(tid,'forn') or public.edita(tid,'lanc')) with check (public.edita(tid,'forn') or public.edita(tid,'lanc'));
create policy del on public.fornecedores for delete to authenticated using (public.edita(tid,'forn'));
-- agenda
create policy sel on public.agenda for select to authenticated using (public.le(tid,'ag') or public.le(tid,'dash'));
create policy ins on public.agenda for insert to authenticated with check (public.edita(tid,'ag'));
create policy upd on public.agenda for update to authenticated using (public.edita(tid,'ag')) with check (public.edita(tid,'ag'));
create policy del on public.agenda for delete to authenticated using (public.edita(tid,'ag'));
-- lojas (todos do franqueado leem: são os centros de custo)
create policy sel on public.lojas for select to authenticated using (public.e_membro(tid) or public.e_rede());
create policy ins on public.lojas for insert to authenticated with check (public.edita(tid,'lojas'));
create policy upd on public.lojas for update to authenticated using (public.edita(tid,'lojas')) with check (public.edita(tid,'lojas'));
create policy del on public.lojas for delete to authenticated using (public.edita(tid,'lojas'));
-- chamados: master do franqueado e rede leem; ações só pelas funções abaixo.
create policy sel on public.chamados for select to authenticated using (public.e_master(tid) or public.e_rede());
-- diário: só acrescenta; ninguém altera nem apaga.
create policy sel on public.diario for select to authenticated using (public.e_master(tid) or public.e_rede());
create policy ins on public.diario for insert to authenticated with check (public.e_membro(tid) or public.e_rede());

grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant all on all tables in schema public to service_role;
revoke all on public.logins from anon, authenticated;

-- ---------------------------------------------------------------------
-- CARIMBOS AUTOMÁTICOS
-- ---------------------------------------------------------------------
-- diário: data/hora e autor vêm do servidor (não dá para falsificar)
create or replace function public.carimbar_diario() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.data := coalesce(new.data,'{}'::jsonb) || jsonb_build_object(
      'uid', auth.uid()::text,
      'nome', coalesce((select data->>'nome' from contas where id = auth.uid()), ''),
      'papel', (select papel from contas where id = auth.uid()));
  end if;
  new.data := new.data || jsonb_build_object('quando', public.iso_agora());
  new.criado := now();
  return new;
end $$;
drop trigger if exists carimbo on public.diario;
create trigger carimbo before insert on public.diario for each row execute function public.carimbar_diario();
drop trigger if exists carimbo on public.rede_diario;
create trigger carimbo before insert on public.rede_diario for each row execute function public.carimbar_diario();

-- último acesso do franqueado (para o painel da rede)
create or replace function public.anotar_acesso() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.data->>'acao' = 'Login' and new.data->>'papel' in ('master','colab') then
    update tenants set data = data || jsonb_build_object('ultimoAcesso', new.data->>'quando', 'ultimoAcessoPor', new.data->>'nome') where id = new.tid;
  end if;
  return null;
end $$;
drop trigger if exists acesso on public.diario;
create trigger acesso after insert on public.diario for each row execute function public.anotar_acesso();

-- contagem de lojas do franqueado
create or replace function public.contar_lojas() returns trigger
language plpgsql security definer set search_path = public as $$
declare t text := coalesce(new.tid, old.tid);
begin
  update tenants set data = data || jsonb_build_object(
    'nLojas', (select count(*) from lojas where tid = t),
    'nLojasAtivas', (select count(*) from lojas where tid = t and coalesce((data->>'ativa')::boolean, true)
                       and coalesce(data->>'inauguracao','') <= to_char(now(),'YYYY-MM-DD')))
   where id = t;
  return null;
end $$;
drop trigger if exists contagem on public.lojas;
create trigger contagem after insert or update or delete on public.lojas for each row execute function public.contar_lojas();

-- data de atualização
create or replace function public.tocar_atualizado() returns trigger language plpgsql as
$$ begin new.atualizado := now(); return new; end $$;
do $$
declare t text;
begin
  foreach t in array array['usuarios','config','lancamentos','fornecedores','agenda','lojas','recorrencias','chamados'] loop
    execute format('drop trigger if exists atualizado on public.%I', t);
    execute format('create trigger atualizado before update on public.%I for each row execute function public.tocar_atualizado()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- FUNÇÕES CHAMADAS PELO APP
-- ---------------------------------------------------------------------
-- Login por CNPJ/CPF: devolve o e-mail ligado ao documento
create or replace function public.resolver_login(p_doc text) returns text
language plpgsql stable security definer set search_path = public as $$
declare e text;
begin
  select email into e from logins where doc = regexp_replace(coalesce(p_doc,''), '\D', '', 'g');
  if e is null then raise exception 'CNPJ/CPF não cadastrado para login.'; end if;
  return e;
end $$;

-- dados do próprio acesso
create or replace function public.meu_acesso() returns jsonb
language sql stable security definer set search_path = public as $$
  select c.data || jsonb_build_object('id', c.id, 'papel', c.papel, 'tid', c.tid, 'ativo', c.ativo, 'trocarSenha', c.trocar_senha,
           'tenantAtivo', coalesce((select coalesce((t.data->>'ativo')::boolean, true) from tenants t where t.id = c.tid), true))
    from contas c where c.id = auth.uid()
$$;
create or replace function public.marcar_senha_trocada() returns void
language sql security definer set search_path = public as
$$ update contas set trocar_senha = false where id = auth.uid() $$;
create or replace function public.registrar_acesso() returns void
language sql security definer set search_path = public as
$$ update contas set data = data || jsonb_build_object('ultimoAcesso', public.iso_agora()) where id = auth.uid() $$;

-- equipe da rede (masters e observadores)
create or replace function public.listar_equipe_rede() returns setof jsonb
language sql stable security definer set search_path = public as $$
  select c.data || jsonb_build_object('id', c.id, 'papel', c.papel, 'ativo', c.ativo)
    from contas c where c.papel in ('master_rede','observador') and public.e_master_rede()
$$;

-- CHAMADOS: a franqueadora pede, o master do franqueado decide
create or replace function public.abrir_chamado(p_tid text, p_tipo text, p_descricao text, p_horas int) returns text
language plpgsql security definer set search_path = public as $$
declare n int; novo text := gen_random_uuid()::text; nome text;
begin
  if not public.e_master_rede() then raise exception 'Só a franqueadora abre chamados.'; end if;
  if coalesce(length(trim(p_descricao)),0) < 5 then raise exception 'Descreva o que precisa ser feito.'; end if;
  select coalesce(max((data->>'numero')::int),0)+1 into n from chamados where tid = p_tid;
  select data->>'nome' into nome from contas where id = auth.uid();
  insert into chamados (id, tid, data) values (novo, p_tid, jsonb_build_object(
    'numero', n, 'status', 'pendente', 'tipo', p_tipo, 'descricao', trim(p_descricao), 'duracaoH', p_horas,
    'solicitadoPor', auth.uid()::text, 'solicitadoPorNome', nome, 'solicitadoEm', public.iso_agora()));
  insert into diario (tid, data) values (p_tid, jsonb_build_object('acao','Chamado aberto','cat','chamado','chamadoId',novo,
    'detalhe', format('#%s — %s: %s (prazo pedido: %s h)', n, p_tipo, trim(p_descricao), p_horas)));
  return novo;
end $$;

create or replace function public.autorizar_chamado(p_id text, p_horas int, p_obs text) returns void
language plpgsql security definer set search_path = public as $$
declare c record; ate text; nome text;
begin
  select * into c from chamados where id = p_id;
  if c is null or not public.e_master(c.tid) then raise exception 'Só o master do franqueado autoriza.'; end if;
  if c.data->>'status' <> 'pendente' then raise exception 'Este chamado já foi respondido.'; end if;
  if p_horas not in (1,4,24,72,168) then raise exception 'Prazo inválido.'; end if;
  ate := to_char((now() + make_interval(hours => p_horas)) at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  select data->>'nome' into nome from contas where id = auth.uid();
  update chamados set data = data || jsonb_build_object('status','aprovado','respondidoPor',auth.uid()::text,'respondidoPorNome',nome,
     'respondidoEm',public.iso_agora(),'validoAte',ate,'duracaoAprovadaH',p_horas,'resposta',coalesce(p_obs,'')) where id = p_id;
  update tenants set data = data || jsonb_build_object('acessoMaster', jsonb_build_object('chamadoId',p_id,'numero',(c.data->>'numero')::int,
     'ate',ate,'liberadoPor',auth.uid()::text,'liberadoPorNome',nome)) where id = c.tid;
  insert into diario (tid, data) values (c.tid, jsonb_build_object('acao','Acesso autorizado','cat','chamado','chamadoId',p_id,
    'detalhe', format('Chamado #%s autorizado por %s h%s', c.data->>'numero', p_horas, case when coalesce(p_obs,'')<>'' then ' — '||p_obs else '' end)));
end $$;

create or replace function public.negar_chamado(p_id text, p_motivo text) returns void
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from chamados where id = p_id;
  if c is null or not public.e_master(c.tid) then raise exception 'Só o master do franqueado responde.'; end if;
  if c.data->>'status' <> 'pendente' then raise exception 'Este chamado já foi respondido.'; end if;
  update chamados set data = data || jsonb_build_object('status','negado','respondidoPor',auth.uid()::text,
    'respondidoPorNome',(select data->>'nome' from contas where id = auth.uid()),'respondidoEm',public.iso_agora(),'resposta',coalesce(p_motivo,'')) where id = p_id;
  insert into diario (tid, data) values (c.tid, jsonb_build_object('acao','Chamado negado','cat','chamado','chamadoId',p_id,
    'detalhe', format('#%s%s', c.data->>'numero', case when coalesce(p_motivo,'')<>'' then ' — '||p_motivo else '' end)));
end $$;

create or replace function public.cancelar_chamado(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select * into c from chamados where id = p_id;
  if c is null or not public.e_master_rede() or c.data->>'solicitadoPor' <> auth.uid()::text then raise exception 'Só quem abriu pode cancelar.'; end if;
  if c.data->>'status' <> 'pendente' then raise exception 'Este chamado já foi respondido.'; end if;
  update chamados set data = data || jsonb_build_object('status','cancelado','encerradoEm',public.iso_agora(),'encerradoPor',auth.uid()::text,
    'encerradoPorNome',(select data->>'nome' from contas where id = auth.uid())) where id = p_id;
  insert into diario (tid, data) values (c.tid, jsonb_build_object('acao','Chamado cancelado','cat','chamado','chamadoId',p_id,'detalhe','#'||(c.data->>'numero')));
end $$;

create or replace function public.encerrar_acesso(p_tid text) returns void
language plpgsql security definer set search_path = public as $$
declare am jsonb; nome text;
begin
  if not (public.e_master(p_tid) or public.e_master_rede()) then raise exception 'Sem permissão.'; end if;
  select data->'acessoMaster' into am from tenants where id = p_tid;
  if am is null or am = 'null'::jsonb then return; end if;
  select data->>'nome' into nome from contas where id = auth.uid();
  update tenants set data = data || jsonb_build_object('acessoMaster', null) where id = p_tid;
  update chamados set data = data || jsonb_build_object('status','encerrado','encerradoEm',public.iso_agora(),'encerradoPor',auth.uid()::text,'encerradoPorNome',nome)
   where id = am->>'chamadoId' and data->>'status' = 'aprovado';
  insert into diario (tid, data) values (p_tid, jsonb_build_object('acao','Acesso encerrado','cat','chamado','chamadoId',am->>'chamadoId',
    'detalhe', format('Acesso de edição do chamado #%s encerrado por %s', am->>'numero', nome)));
end $$;

-- INDICADORES DA REDE: soma mensal por franqueado, calculada direto dos lançamentos
create or replace function public.indicadores_rede(p_ini text, p_fim text)
returns table(tid text, mes text, fat bigint, rec bigint, desp bigint, recebido bigint, pago bigint, ab_rec bigint, ab_pag bigint)
language sql stable security definer set search_path = public as $$
  with plano as (
    select distinct on (x->>'id') x->>'id' as cid, x->>'grupo' as grupo
      from rede_config r, jsonb_array_elements(coalesce(r.data->'categorias','[]'::jsonb)) x where r.id = 'plano'),
  extra as (
    select distinct on (c.tid, x->>'id') c.tid, x->>'id' as cid, x->>'grupo' as grupo
      from config c, jsonb_array_elements(coalesce(c.data->'categoriasExtra','[]'::jsonb) || coalesce(c.data->'categorias','[]'::jsonb)) x),
  l as (
    select l.tid, l.data as d, coalesce((l.data->>'valor')::numeric,0)::bigint as v,
           coalesce(e.grupo, p.grupo,
             case when l.data->>'categoria' like 'rec\_%' then 'receita' when l.data->>'categoria' like 'inv\_%' then 'invest' end,
             case when l.data->>'tipo' = 'receita' then 'receita' else 'adm' end) as g
      from lancamentos l
      left join extra e on e.tid = l.tid and e.cid = l.data->>'categoria'
      left join plano p on p.cid = l.data->>'categoria'),
  c as (
    select l.tid, left(coalesce(d->>'competencia', d->>'dataLanc', d->>'venc'), 7) as mes,
           case when d->>'tipo'='receita' and g='receita' then v else 0 end as fat,
           case when d->>'tipo'='receita' then v else 0 end as rec,
           case when d->>'tipo'<>'receita' and g<>'invest' then v else 0 end as desp,
           0::bigint as recebido, 0::bigint as pago, 0::bigint as ab_rec, 0::bigint as ab_pag
      from l
    union all
    select l.tid, left(d->>'pago',7), 0,0,0, case when d->>'tipo'='receita' then v else 0 end, case when d->>'tipo'<>'receita' then v else 0 end, 0,0
      from l where coalesce(d->>'pago','') <> ''
    union all
    select l.tid, left(d->>'venc',7), 0,0,0,0,0, case when d->>'tipo'='receita' then v else 0 end, case when d->>'tipo'<>'receita' then v else 0 end
      from l where coalesce(d->>'pago','') = '' and coalesce(d->>'venc','') <> '')
  select c.tid, c.mes, sum(c.fat)::bigint, sum(c.rec)::bigint, sum(c.desp)::bigint, sum(c.recebido)::bigint, sum(c.pago)::bigint, sum(c.ab_rec)::bigint, sum(c.ab_pag)::bigint
    from c where public.e_master_rede() and c.mes between p_ini and p_fim
   group by c.tid, c.mes
$$;

-- ---------------------------------------------------------------------
-- ADMINISTRAÇÃO (só pelo SQL Editor do Supabase — o app não consegue chamar)
-- ---------------------------------------------------------------------
-- 1) Crie o usuário em Authentication → Users → Add user (e-mail + senha, "Auto Confirm").
-- 2) Rode:  select public.definir_master_rede('seu@email.com', '12345678000190', 'Seu Nome', 'Empresa Ltda', '(11) 90000-0000');
create or replace function public.definir_master_rede(p_email text, p_cnpj text, p_nome text, p_empresa text default '', p_telefone text default '')
returns text language plpgsql security definer set search_path = public as $$
declare u uuid; d text := regexp_replace(coalesce(p_cnpj,''), '\D', '', 'g');
begin
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then raise exception 'Usuário % não encontrado. Crie primeiro em Authentication → Users → Add user.', p_email; end if;
  if length(d) not in (11,14) then raise exception 'CNPJ (14 dígitos) ou CPF (11) inválido.'; end if;
  insert into contas (id, papel, tid, ativo, trocar_senha, data)
  values (u, 'master_rede', null, true, false, jsonb_build_object('nome',p_nome,'email',lower(trim(p_email)),'login',d,'empresa',p_empresa,'telefone',p_telefone))
  on conflict (id) do update set papel='master_rede', ativo=true, data = contas.data || excluded.data;
  insert into logins (doc, email, uid, tid) values (d, lower(trim(p_email)), u, null)
  on conflict (doc) do update set email = excluded.email, uid = excluded.uid;
  insert into rede_diario (data) values (jsonb_build_object('uid',u::text,'nome',p_nome,'papel','master_rede','acao','Master da rede definido','detalhe','Pelo SQL Editor do Supabase'));
  return 'OK — login: ' || d;
end $$;

-- Recuperar a senha master sem e-mail:  select public.redefinir_senha_master('12345678000190', 'NovaSenha2026');
create or replace function public.redefinir_senha_master(p_cnpj text, p_senha text)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare l record;
begin
  select * into l from logins where doc = regexp_replace(coalesce(p_cnpj,''), '\D', '', 'g');
  if l is null then raise exception 'Login não encontrado.'; end if;
  if length(p_senha) < 8 then raise exception 'Use pelo menos 8 caracteres.'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_senha, extensions.gen_salt('bf')), banned_until = null where id = l.uid;
  update contas set trocar_senha = true, ativo = true where id = l.uid;
  insert into rede_diario (data) values (jsonb_build_object('uid',l.uid::text,'nome','SQL Editor','papel','master_rede','acao','Senha redefinida','detalhe','Login '||l.doc));
  return 'OK — entre com a nova senha; o sistema vai pedir para trocar.';
end $$;

-- permissões de execução: funções de administração ficam fora do alcance do app
revoke execute on function public.definir_master_rede(text,text,text,text,text) from public, anon, authenticated;
revoke execute on function public.redefinir_senha_master(text,text) from public, anon, authenticated;
grant execute on function public.resolver_login(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- TEMPO REAL (as telas atualizam sozinhas quando alguém grava)
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['tenants','rede_config','rede_diario','usuarios','config','lancamentos','fornecedores','agenda','lojas','recorrencias','chamados','diario'] loop
      if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
