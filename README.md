# ERP MiniMart — guia de publicação (Supabase + GitHub Pages)

**Como o sistema fica publicado:**
- **Supabase:** login, banco de dados (PostgreSQL, região São Paulo), regras de segurança e a função do servidor.
- **GitHub Pages:** hospeda as telas do sistema. É gratuito e aceita domínio próprio com HTTPS.

```
erp-minimart/
├── docs/
│   ├── index.html                  ← o sistema (todas as telas)
│   └── config.js                   ← endereço e chave pública do Supabase (você preenche)
├── supabase/
│   ├── 01-banco.sql                ← tabelas, regras de segurança e funções (colar no SQL Editor)
│   ├── funcao-admin/index.ts       ← função do servidor: criar logins, senhas, matriz, suspensão
│   └── email-recuperar-senha.html  ← e-mail de "esqueci minha senha" em português
└── GUIA.md                         ← este guia
```

**Tempo estimado:** cerca de 1 hora, tudo pelo navegador, sem instalar nada.

**Custo:** o projeto entra na sua organização Pro do Supabase (em torno de US$ 10 por mês a mais, conforme o tamanho), e o GitHub Pages é gratuito.

**Já testado:** este pacote rodou de ponta a ponta contra os mesmos componentes que o Supabase usa por dentro (PostgreSQL, servidor de login, API e função): logins, chamados, colaboradores, suspensão e recuperação de senha por e-mail. As 50 regras de segurança foram conferidas uma a uma. O primeiro uso no seu Supabase é a validação final, com a lista da Parte 3.

---

## Parte 1 — Supabase

### 1. Criar o projeto
1. Em **supabase.com/dashboard**, escolha a sua **organização Pro** → **New project**.
2. **Name:** `erp-minimart`. **Database password:** gere uma senha forte e guarde-a.
3. **Region:** **South America (São Paulo)**.
4. Clique em **Create new project** e aguarde de 1 a 2 minutos.

### 2. Criar o banco de dados
1. Menu **SQL Editor** → **New query**.
2. Abra o arquivo `supabase/01-banco.sql`, copie **tudo** e cole no editor.
3. Clique em **Run**. Deve aparecer *Success. No rows returned*.

O script pode ser rodado de novo no futuro sem apagar dados.

### 3. Publicar a função do servidor
1. Menu **Edge Functions** → **Deploy a new function** → **Via Editor**.
2. **Nome da função:** `admin` (exatamente assim).
3. Apague o código de exemplo, cole o conteúdo de `supabase/funcao-admin/index.ts` e clique em **Deploy function**.
4. Deixe ligada a opção **Verify JWT** (o padrão).

### 4. Configurar o login
1. **Authentication → Sign In / Providers:**
   - **Email:** ligado.
   - **Allow new users to sign up:** **desligado**. Só o sistema cria acessos.
2. **Authentication → Emails → Templates → Reset password:**
   - **Subject:** `ERP MiniMart — criar nova senha`.
   - **Message body:** cole o conteúdo de `supabase/email-recuperar-senha.html`.
3. **Authentication → Emails → SMTP Settings:** ligue um serviço de e-mail próprio.
   - O envio que vem embutido no Supabase tem limite de poucos e-mails por hora e serve só para testes.
   - Sugestão: **Resend** (resend.com, plano gratuito com 3.000 e-mails por mês). Crie a conta, valide o seu domínio (ex.: minimart.com.br) e gere uma *API key*. No Supabase, preencha:
     - **Host:** `smtp.resend.com`
     - **Port:** `465`
     - **Username:** `resend`
     - **Password:** a API key
     - **Sender email:** `nao-responda@minimart.com.br`
     - **Sender name:** `ERP MiniMart`
   - Depois, em **Authentication → Rate Limits**, ajuste "Rate limit for sending emails" para algo como 100 por hora.

A **URL Configuration** (endereço do site) fica para o passo 9, depois que o endereço do GitHub existir.

### 5. Criar o seu acesso master
1. **Authentication → Users → Add user → Create new user**:
   - **E-mail:** o seu (é para onde vai o link de "esqueci minha senha");
   - **Senha:** a sua senha;
   - marque **Auto Confirm User**.
2. **SQL Editor → New query**, cole a linha abaixo trocando pelos seus dados e clique em **Run**:
   ```sql
   select public.definir_master_rede('seu@email.com', '12345678000190', 'Seu Nome', 'MiniMart Franquias Ltda', '(11) 90000-0000');
   ```
   O segundo valor é o **CNPJ da franqueadora**, que é o seu login. A resposta deve ser `OK — login: 12345678000190`.

### 6. Copiar a chave pública
1. **Project Settings → API Keys**. Em projetos novos, abra a aba **Legacy API keys**.
2. Copie a **Project URL** (ex.: `https://abcdefgh.supabase.co`) e a chave **anon public**.
3. Abra o arquivo `docs/config.js` e substitua `COLE_AQUI_A_PROJECT_URL` e `COLE_AQUI_A_ANON_KEY`.

A chave *anon* é pública por natureza e pode ficar no GitHub: quem protege os dados são as regras do banco. **Nunca** coloque a chave `service_role` em nenhum arquivo.

---

## Parte 2 — GitHub Pages

### 7. Criar o repositório
1. Em **github.com** → **New repository**. **Nome:** `erp-minimart`.
2. **Público ou privado?** O GitHub Pages gratuito exige repositório **público**. O código ser público não expõe nenhum dado, porque os dados ficam no Supabase, protegidos pelas regras. Para repositório **privado**, é preciso o plano GitHub Pro (US$ 4 por mês).
3. Clique em **Create repository**.

### 8. Enviar os arquivos e ligar o Pages
1. No repositório vazio, clique em **uploading an existing file**.
2. Arraste as pastas **`docs`** e **`supabase`** e o arquivo **`GUIA.md`**, já com o `config.js` preenchido → **Commit changes**.
3. **Settings → Pages:**
   - **Source:** *Deploy from a branch*
   - **Branch:** `main`
   - **Pasta:** `/docs`
   - **Save**
4. Em 1 a 2 minutos aparece o endereço, por exemplo `https://seuusuario.github.io/erp-minimart/`.

### 9. Avisar o Supabase sobre o endereço
No Supabase, em **Authentication → URL Configuration**:
- **Site URL:** `https://seuusuario.github.io/erp-minimart/`
- **Redirect URLs:** adicione o mesmo endereço, e depois também o domínio próprio, quando houver.

Sem isso, o link de "esqueci minha senha" não volta para o sistema.

### 10. Entrar pela primeira vez
Abra o endereço e entre com o **CNPJ da franqueadora** e a sua senha. Você deve cair no **Painel da rede**.

### 11. Domínio próprio (opcional, ex.: erp.minimart.com.br)
1. GitHub → **Settings → Pages → Custom domain**: `erp.minimart.com.br` → **Save**.
2. No registro.br (ou onde está o domínio), crie um registro **CNAME**: nome `erp`, valor `seuusuario.github.io`.
3. Quando o GitHub confirmar, marque **Enforce HTTPS**.
4. No Supabase, atualize a **Site URL** e as **Redirect URLs** (passo 9) para `https://erp.minimart.com.br/`.

---

## Parte 3 — Conferência (20 minutos)

| # | Teste | Resultado esperado |
|---|---|---|
| 1 | Entrar com o CNPJ da franqueadora | Abre o *Painel da rede* |
| 2 | *Franqueados → + Novo franqueado* (use um de teste) | Mensagem com login (CNPJ) e senha temporária |
| 3 | Sair e entrar com o CNPJ do franqueado | Pede para criar a senha e abre o Dashboard |
| 4 | Como franqueado, "Esqueci minha senha" | O e-mail chega no e-mail principal da matriz, e o link abre a tela de nova senha |
| 5 | Criar colaborador: Lançamentos = editar, Fornecedores = só leitura | Ele entra com o CPF e vê só essas telas |
| 6 | Como master, entrar no franqueado e tentar criar algo | Não consegue (modo leitura) |
| 7 | Abrir chamado; o franqueado autoriza | Você edita; tudo aparece no *Diário* |
| 8 | Fazer um lançamento de receita no franqueado | O *Painel da rede* mostra o valor (botão *Atualizar números*) |
| 9 | Abrir o sistema em duas abas e gravar algo numa delas | A outra atualiza sozinha em segundos |
| 10 | Suspender o franqueado de teste | O login dele é bloqueado |

Se algo falhar, anote a mensagem e o número do teste e envie ao Claude.

---

## Parte 4 — Como usar

| Quem | Login | Recupera a senha pelo |
|---|---|---|
| Você e outros masters da rede | CNPJ (ou CPF) | e-mail do seu acesso |
| Master do franqueado | **CNPJ da matriz** | **e-mail principal da matriz** |
| Colaborador do franqueado | **CPF** | e-mail do cadastro do colaborador |
| Observador | CPF | e-mail do cadastro |

As regras de uso são as mesmas que combinamos:
- **Área master:** o painel da rede, a lista de franqueados (cadastrar, suspender e reativar), o plano de contas da rede, a equipe da rede, o diário da rede e o seu cadastro.
- **Dentro de um franqueado:** você só lê e só edita a matriz. As demais alterações dependem de um chamado autorizado pelo master do franqueado.
- **Master do franqueado:** acesso total à conta dele, exceto à matriz. Cadastra colaboradores com acessos por tela, e Contas a pagar e a receber são exclusivas dele.
- **Diário:** permanente. O próprio banco de dados impede alterações e exclusões.

---

## Parte 5 — Recuperar a senha master

1. **Pelo sistema:** na tela de login, clique em *Esqueci minha senha* e digite o seu CNPJ.
2. **Sem acesso ao e-mail:** no Supabase, abra **SQL Editor** e rode:
   ```sql
   select public.redefinir_senha_master('12345678000190', 'NovaSenha2026');
   ```
   Entre com essa senha. O sistema vai pedir para criar uma nova.
3. Esse comando só funciona pelo painel do Supabase. O sistema não consegue chamá-lo. Por isso, proteja a conta do Supabase com **verificação em duas etapas**.

## Parte 6 — Manutenção

- **Atualizar o sistema:** no GitHub, abra `docs/index.html` → ícone de lápis → cole a nova versão → *Commit*. Em 1 a 2 minutos está no ar. Se a atualização mudar o banco ou a função, o arquivo correspondente vem junto: rode o `.sql` de novo no SQL Editor e/ou cole a função nova no editor da Edge Function.
- **Backup:** o plano Pro faz backup diário automático. Veja em **Database → Backups**.
- **Relatórios externos (BI):** os dados estão em PostgreSQL. Ferramentas como Power BI, Metabase ou Google Looker Studio podem se conectar ao banco. Para isso, crie um usuário somente leitura antes.
- **LGPD:** o sistema guarda CPF, telefone e data de nascimento de colaboradores. Tenha termo de uso e política de privacidade, e informe os franqueados sobre o acesso de leitura da franqueadora e dos observadores.
- **Segurança:**
  - ative a verificação em duas etapas no Supabase e no GitHub;
  - nunca publique a chave `service_role`;
  - suspenda franqueados que saírem da rede, em vez de apagar.
