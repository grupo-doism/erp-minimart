// =====================================================================
// ERP MiniMart — função do servidor "admin" (Supabase Edge Function)
// Tudo que envolve criar logins, senhas e perfis roda aqui, com a chave
// de serviço (que nunca vai para o navegador).
// Supabase → Edge Functions → Deploy a new function → Via Editor →
// nome: admin → cole este arquivo → Deploy.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL");
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const admin = createClient(URL, KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const resp = (obj) => new Response(JSON.stringify(obj), { status: 200, headers: { ...CORS, "Content-Type": "application/json" } });
class Erro extends Error {}
const falha = (m) => { throw new Erro(m); };
const negar = (m) => falha(m || "Você não tem permissão para esta ação.");

const REDE = ["master_rede", "observador"];
const dig = (s) => String(s || "").replace(/\D/g, "");
const emailOk = (e) => /^\S+@\S+\.\S+$/.test(String(e || "").trim());
const agora = () => new Date().toISOString();
const fmtCpf = (d) => d.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, "$1.$2.$3-$4");
const senhaBoa = (s) => typeof s === "string" && s.length >= 8 && /[A-Za-z]/.test(s) && /\d/.test(s);
const dataOk = (d) => !d || /^\d{4}-\d{2}-\d{2}$/.test(d);
const BAN = "876000h"; // ~100 anos = bloqueado

function senhaTemp() {
  const A = "ABCDEFGHJKLMNPQRSTUVWXYZ", a = "abcdefghijkmnpqrstuvwxyz", n = "23456789";
  const r = (max) => crypto.getRandomValues(new Uint32Array(1))[0] % max;
  const pick = (s) => s[r(s.length)];
  const c = [pick(A), pick(a), pick(n), pick(n)];
  for (let i = 0; i < 6; i++) c.push(pick(A + a + n));
  for (let i = c.length - 1; i > 0; i--) { const j = r(i + 1); [c[i], c[j]] = [c[j], c[i]]; }
  return c.join("");
}

// ---------- acesso ao banco (com a chave de serviço) ----------
async function q1(tab, col, val) {
  const { data, error } = await admin.from(tab).select("*").eq(col, val).maybeSingle();
  if (error) falha(error.message);
  return data;
}
async function ok(p) { const { error } = await p; if (error) falha(error.message); }
async function registrar(tid, quem, acao, detalhe, cat) {
  const data = { uid: quem.uid, nome: quem.nome, papel: quem.papel, acao, detalhe: detalhe || "", cat: cat || "usuario", origem: "servidor" };
  if (tid) await admin.from("diario").insert({ tid, data });
  else await admin.from("rede_diario").insert({ data });
}
async function tenantLiberado(tid) {
  const t = tid && (await q1("tenants", "id", tid));
  const am = t && t.data && t.data.acessoMaster;
  return !!(am && am.ate && new Date(am.ate).getTime() > Date.now());
}
async function podeGerir(quem, tid) { return (quem.tid === tid && quem.papel === "master") || (quem.papel === "master_rede" && (await tenantLiberado(tid))); }

async function criarLogin(email, senha, nome) {
  const { data, error } = await admin.auth.admin.createUser({ email: String(email).trim().toLowerCase(), password: senha, email_confirm: true, user_metadata: { nome } });
  if (error) falha(/already|registered|exists/i.test(error.message) ? "Este e-mail já tem um acesso ao ERP." : "Não foi possível criar o acesso: " + error.message);
  return data.user;
}
async function trocarEmail(uid, email) {
  const { error } = await admin.auth.admin.updateUserById(uid, { email, email_confirm: true });
  if (error) falha(/already|registered|exists/i.test(error.message) ? "Este e-mail já é usado por outro acesso." : error.message);
}
async function bloquear(uid, bloqueado) {
  const { error } = await admin.auth.admin.updateUserById(uid, { ban_duration: bloqueado ? BAN : "none" });
  if (error) falha(error.message);
}

// ---------- matriz ----------
const CAMPOS_MZ = ["razao", "cnpj", "regional", "franq1", "franq2", "franq3", "endereco", "email", "telefone", "email2", "telefone2"];
const NOMES_MZ = { razao: "Razão social", cnpj: "CNPJ (login)", regional: "Regional", franq1: "Franqueado 1", franq2: "Franqueado 2", franq3: "Franqueado 3", endereco: "Endereço", email: "E-mail principal (recuperação)", telefone: "Telefone", email2: "E-mail adicional", telefone2: "Telefone adicional" };
function limparMatriz(m) {
  const mz = {}; CAMPOS_MZ.forEach((k) => (mz[k] = String((m || {})[k] || "").trim()));
  if (!mz.razao) falha("Informe a razão social.");
  if (dig(mz.cnpj).length !== 14) falha("CNPJ inválido.");
  if (!mz.franq1) falha("Informe o nome do franqueado 1.");
  if (!emailOk(mz.email)) falha("Informe o e-mail principal — ele é usado para recuperar a senha.");
  mz.email = mz.email.toLowerCase();
  return mz;
}

// ---------- colaboradores ----------
const MODS = { dash: 1, fluxo: 1, dre: 1, lanc: 2, forn: 2, ag: 2, lojas: 2, config: 2 }; // contas a pagar/receber: só o master
const MOD_NOME = { dash: "Dashboard", fluxo: "Fluxo de caixa", dre: "DRE", lanc: "Lançamentos", forn: "Fornecedores", ag: "Agenda", lojas: "Lojas", config: "Plano de contas" };
const NIVEL_NOME = ["não acessa", "só leitura", "edita"];
function limparPerm(p) { const o = {}; for (const k in MODS) { const v = Math.round(+((p || {})[k]) || 0); o[k] = Math.max(0, Math.min(MODS[k], v)); } return o; }

// =====================================================================
const ACOES = {
  /** Franqueadora cadastra um franqueado. Login = CNPJ da matriz; recuperação = e-mail principal. */
  async criarFranqueado(q, b) {
    if (q.papel !== "master_rede") negar("Só o master da rede cadastra franqueados.");
    const mz = limparMatriz(b.matriz); const cnpj = dig(mz.cnpj);
    if (await q1("logins", "doc", cnpj)) falha("Já existe um acesso com este CNPJ.");
    const tid = crypto.randomUUID().replace(/-/g, "").slice(0, 20);
    const senha = senhaTemp();
    const u = await criarLogin(mz.email, senha, mz.franq1);
    try {
      await ok(admin.from("tenants").insert({ id: tid, data: { nome: String(b.nome || mz.razao).trim(), cnpjDig: cnpj, matriz: mz, ativo: true, masterUid: u.id, acessoMaster: null, nLojas: 0, nLojasAtivas: 0, criado: agora(), criadoPor: q.uid } }));
      await ok(admin.from("contas").insert({ id: u.id, papel: "master", tid, ativo: true, trocar_senha: true, data: { nome: mz.franq1, email: u.email, login: cnpj } }));
      await ok(admin.from("logins").insert({ doc: cnpj, email: u.email, uid: u.id, tid }));
      await ok(admin.from("usuarios").insert({ id: u.id, tid, data: { nome: mz.franq1, email: u.email, login: cnpj, perfil: "master", ativo: true, criado: agora() } }));
    } catch (e) {
      await admin.from("logins").delete().eq("doc", cnpj);
      await admin.from("tenants").delete().eq("id", tid);
      await admin.auth.admin.deleteUser(u.id);
      throw e;
    }
    await registrar(tid, q, "Franqueado cadastrado", `Conta criada pela franqueadora. Login: CNPJ ${mz.cnpj} · recuperação: ${u.email}`);
    await registrar(null, q, "Franqueado cadastrado", `${mz.razao} — CNPJ ${mz.cnpj}`);
    return { tid, email: u.email, senha, login: cnpj };
  },

  /** Franqueadora altera a matriz; login (CNPJ) e e-mail de recuperação acompanham. */
  async salvarMatriz(q, b) {
    if (q.papel !== "master_rede") negar("Só a franqueadora altera a matriz.");
    const t = await q1("tenants", "id", b.tid); if (!t) falha("Franqueado não encontrado.");
    const antes = t.data.matriz || {}; const mz = limparMatriz(b.matriz);
    const mud = CAMPOS_MZ.filter((k) => (antes[k] || "") !== (mz[k] || ""));
    if (!mud.length) return { alterados: 0 };
    const novo = dig(mz.cnpj), velho = t.data.cnpjDig, mUid = t.data.masterUid;
    if (novo !== velho && (await q1("logins", "doc", novo))) falha("Este CNPJ já é usado por outro acesso.");
    if (mUid && mz.email !== String(antes.email || "").toLowerCase()) {
      await trocarEmail(mUid, mz.email);
      const c = await q1("contas", "id", mUid);
      await ok(admin.from("contas").update({ data: { ...c.data, email: mz.email, login: novo, nome: mz.franq1 } }).eq("id", mUid));
      const us = await q1("usuarios", "id", mUid);
      if (us) await ok(admin.from("usuarios").update({ data: { ...us.data, email: mz.email, login: novo, nome: mz.franq1 } }).eq("id", mUid));
    } else if (mUid && (novo !== velho || mud.includes("franq1"))) {
      const c = await q1("contas", "id", mUid);
      await ok(admin.from("contas").update({ data: { ...c.data, login: novo, nome: mz.franq1 } }).eq("id", mUid));
    }
    if (mUid && (novo !== velho || mud.includes("email"))) {
      if (velho && novo !== velho) await admin.from("logins").delete().eq("doc", velho);
      await ok(admin.from("logins").upsert({ doc: novo, email: mz.email, uid: mUid, tid: b.tid }));
    }
    await ok(admin.from("tenants").update({ data: { ...t.data, matriz: mz, cnpjDig: novo, atualizado: agora() } }).eq("id", b.tid));
    await registrar(b.tid, q, "Matriz alterada", mud.map((k) => `${NOMES_MZ[k]}: "${antes[k] || ""}" → "${mz[k] || ""}"`).join(" · "), "matriz");
    await registrar(null, q, "Matriz alterada", `${mz.razao} — ${mud.map((k) => NOMES_MZ[k]).join(", ")}`, "matriz");
    return { alterados: mud.length };
  },

  /** Suspende (bloqueia todos os logins) ou reativa um franqueado. */
  async alterarFranqueado(q, b) {
    if (q.papel !== "master_rede") negar();
    const t = await q1("tenants", "id", b.tid); if (!t) falha("Franqueado não encontrado.");
    const { data: cs } = await admin.from("contas").select("id,ativo").eq("tid", b.tid);
    for (const c of cs || []) await bloquear(c.id, !b.ativo || c.ativo === false);
    await ok(admin.from("tenants").update({ data: { ...t.data, ativo: !!b.ativo, atualizado: agora() } }).eq("id", b.tid));
    await registrar(b.tid, q, b.ativo ? "Franqueado reativado" : "Franqueado suspenso", b.ativo ? "Logins liberados pela franqueadora" : "Todos os logins bloqueados pela franqueadora");
    await registrar(null, q, b.ativo ? "Franqueado reativado" : "Franqueado suspenso", (t.data.matriz || {}).razao || b.tid);
    return {};
  },

  /** Contas da rede atualizam os próprios dados. */
  async atualizarMeuCadastro(q, b) {
    if (!REDE.includes(q.papel)) negar();
    const nome = String(b.nome || "").trim(); if (!nome) falha("Informe o nome.");
    if (!emailOk(b.email)) falha("Informe um e-mail válido para recuperação de senha.");
    const em = String(b.email).trim().toLowerCase();
    const c = await q1("contas", "id", q.uid);
    if (em !== c.data.email) { await trocarEmail(q.uid, em); if (c.data.login) await ok(admin.from("logins").update({ email: em }).eq("doc", c.data.login)); }
    await ok(admin.from("contas").update({ data: { ...c.data, nome, empresa: String(b.empresa || "").trim(), telefone: String(b.telefone || "").trim(), email: em } }).eq("id", q.uid));
    await registrar(null, q, "Cadastro atualizado", `${nome} atualizou os próprios dados`);
    return {};
  },

  /** Master do franqueado cadastra colaborador: login = CPF; senha digitada ou gerada; acessos por tela. */
  async criarUsuario(q, b) {
    if (!b.tid) falha("Franqueado não informado.");
    if (!(await podeGerir(q, b.tid))) negar("Só o master do franqueado cadastra colaboradores.");
    const login = dig(b.cpf); const nome = String(b.nome || "").trim();
    if (!nome) falha("Informe o nome.");
    if (login.length !== 11) falha("Informe o CPF (11 dígitos) — ele é o login.");
    if (!emailOk(b.email)) falha("Informe um e-mail válido — ele é usado para recuperar a senha.");
    if (!dataOk(b.nascimento)) falha("Data de nascimento inválida.");
    if (b.senha && !senhaBoa(b.senha)) falha("A senha precisa ter pelo menos 8 caracteres, com letras e números.");
    if (await q1("logins", "doc", login)) falha("Este CPF já tem acesso ao ERP.");
    const p = limparPerm(b.perm); const senha = b.senha || senhaTemp(); const tel = String(b.telefone || "").trim();
    const u = await criarLogin(b.email, senha, nome);
    try {
      await ok(admin.from("contas").insert({ id: u.id, papel: "colab", tid: b.tid, ativo: true, trocar_senha: b.trocar !== false, data: { nome, email: u.email, login, telefone: tel } }));
      await ok(admin.from("logins").insert({ doc: login, email: u.email, uid: u.id, tid: b.tid }));
      await ok(admin.from("usuarios").insert({ id: u.id, tid: b.tid, data: { nome, email: u.email, login, telefone: tel, nascimento: b.nascimento || null, perfil: "colab", perm: p, ativo: true, criado: agora(), criadoPor: q.uid } }));
    } catch (e) { await admin.from("logins").delete().eq("doc", login); await admin.auth.admin.deleteUser(u.id); throw e; }
    const acessos = Object.keys(MODS).filter((k) => p[k]).map((k) => `${MOD_NOME[k]} (${NIVEL_NOME[p[k]]})`).join(", ") || "nenhuma tela";
    await registrar(b.tid, q, "Colaborador cadastrado", `${nome} — CPF ${fmtCpf(login)} · acessos: ${acessos}`, q.papel === "master_rede" ? "alteracao" : "usuario");
    return { email: u.email, senha, login, definida: !!b.senha, trocar: b.trocar !== false };
  },

  /** Master do franqueado altera dados, acessos ou situação de um colaborador. */
  async editarUsuario(q, b) {
    const c = await q1("contas", "id", b.uid); if (!c) falha("Colaborador não encontrado.");
    if (c.papel !== "colab") negar("O master do franqueado não pode ser alterado por aqui.");
    if (!(await podeGerir(q, c.tid)) || b.uid === q.uid) negar();
    const nome = String(b.nome || "").trim(); if (!nome) falha("Informe o nome.");
    if (!emailOk(b.email)) falha("E-mail inválido.");
    if (!dataOk(b.nascimento)) falha("Data de nascimento inválida.");
    const em = String(b.email).trim().toLowerCase(); const p = limparPerm(b.perm); const at = b.ativo !== false; const tel = String(b.telefone || "").trim();
    if (em !== c.data.email) { await trocarEmail(b.uid, em); if (c.data.login) await ok(admin.from("logins").update({ email: em }).eq("doc", c.data.login)); }
    await bloquear(b.uid, !at);
    const us = await q1("usuarios", "id", b.uid); const antes = (us && us.data) || {};
    await ok(admin.from("contas").update({ ativo: at, data: { ...c.data, nome, email: em, telefone: tel } }).eq("id", b.uid));
    await ok(admin.from("usuarios").update({ data: { ...antes, nome, email: em, telefone: tel, nascimento: b.nascimento || null, perm: p, ativo: at } }).eq("id", b.uid));
    const mud = []; const pa = antes.perm || {};
    Object.keys(MODS).forEach((k) => { if ((pa[k] || 0) !== p[k]) mud.push(`${MOD_NOME[k]}: ${NIVEL_NOME[pa[k] || 0]} → ${NIVEL_NOME[p[k]]}`); });
    if ((antes.ativo !== false) !== at) mud.push(at ? "acesso reativado" : "acesso bloqueado");
    for (const [k, n] of [["nome", nome], ["email", em], ["telefone", tel], ["nascimento", b.nascimento || null]]) if ((antes[k] || "") !== (n || "")) mud.push(`${k}: "${antes[k] || ""}" → "${n || ""}"`);
    await registrar(c.tid, q, "Colaborador alterado", `${nome}: ${mud.join(" · ") || "sem mudanças"}`, q.papel === "master_rede" ? "alteracao" : "usuario");
    return {};
  },

  /** Nova senha (digitada pelo master ou gerada) para colaborador ou acesso da rede. */
  async novaSenhaTemp(q, b) {
    if (!b.uid || b.uid === q.uid) negar('Para a sua própria senha, use "Trocar senha" ou "Esqueci minha senha".');
    const c = await q1("contas", "id", b.uid); if (!c) falha("Usuário não encontrado.");
    const pode = REDE.includes(c.papel) ? q.papel === "master_rede" : c.papel === "colab" && (await podeGerir(q, c.tid));
    if (!pode) negar();
    if (b.senha && !senhaBoa(b.senha)) falha("A senha precisa ter pelo menos 8 caracteres, com letras e números.");
    const senha = b.senha || senhaTemp();
    const { error } = await admin.auth.admin.updateUserById(b.uid, { password: senha }); if (error) falha(error.message);
    await ok(admin.from("contas").update({ trocar_senha: b.trocar !== false }).eq("id", b.uid));
    await registrar(REDE.includes(c.papel) ? null : c.tid, q, b.senha ? "Senha redefinida" : "Senha temporária gerada", `Para ${c.data.nome || c.data.email}`);
    return { email: c.data.email, senha, login: c.data.login || null, definida: !!b.senha, trocar: b.trocar !== false };
  },

  /** Master da rede cria outro master da rede ou um observador. */
  async criarContaRede(q, b) {
    if (q.papel !== "master_rede") negar();
    if (!REDE.includes(b.papel)) falha("Perfil inválido.");
    const nome = String(b.nome || "").trim(); if (!nome || !emailOk(b.email)) falha("Informe nome e e-mail válidos.");
    const d = dig(b.login); if (d.length !== 11 && d.length !== 14) falha("Informe o CPF (11 dígitos) ou CNPJ (14) — ele é o login.");
    if (await q1("logins", "doc", d)) falha("Este CNPJ/CPF já é usado como login.");
    const senha = senhaTemp(); const u = await criarLogin(b.email, senha, nome);
    try {
      await ok(admin.from("contas").insert({ id: u.id, papel: b.papel, tid: null, ativo: true, trocar_senha: true, data: { nome, email: u.email, login: d } }));
      await ok(admin.from("logins").insert({ doc: d, email: u.email, uid: u.id, tid: null }));
    } catch (e) { await admin.from("logins").delete().eq("doc", d); await admin.auth.admin.deleteUser(u.id); throw e; }
    await registrar(null, q, "Acesso da rede criado", `${nome} (${u.email}) — ${b.papel === "observador" ? "Observador" : "Master da rede"}`);
    return { email: u.email, senha, login: d };
  },

  /** Master da rede desativa/reativa acessos da rede. */
  async alterarContaRede(q, b) {
    if (q.papel !== "master_rede") negar();
    if (!b.uid || b.uid === q.uid) negar("Você não pode desativar o próprio acesso.");
    const c = await q1("contas", "id", b.uid); if (!c || !REDE.includes(c.papel)) falha("Acesso não encontrado.");
    await bloquear(b.uid, !b.ativo);
    await ok(admin.from("contas").update({ ativo: !!b.ativo }).eq("id", b.uid));
    await registrar(null, q, b.ativo ? "Acesso da rede reativado" : "Acesso da rede desativado", `${c.data.nome} (${c.data.email})`);
    return {};
  },
};

// =====================================================================
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: ud, error: ue } = await admin.auth.getUser(token);
    if (ue || !ud || !ud.user) falha("Faça login novamente.");
    const conta = await q1("contas", "id", ud.user.id);
    if (!conta || !conta.ativo) negar("Acesso desativado.");
    if (conta.tid) { const t = await q1("tenants", "id", conta.tid); if (!t || t.data.ativo === false) negar("Franqueado suspenso."); }
    const quem = { uid: ud.user.id, papel: conta.papel, tid: conta.tid, nome: (conta.data && conta.data.nome) || ud.user.email };
    const body = await req.json();
    const acao = ACOES[body && body.acao];
    if (!acao) falha("Ação desconhecida.");
    const r = await acao(quem, body);
    return resp({ ok: true, ...(r || {}) });
  } catch (e) {
    return resp({ ok: false, erro: e instanceof Erro ? e.message : "Erro no servidor: " + (e && e.message) });
  }
});
