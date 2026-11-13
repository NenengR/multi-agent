# Fase 1, Condor Multi-Agent Trading, Laporan Perbaikan Repo

Tanggal: 12 Nov 2026, 12:31 WIB
Lead: HAMID
Repo asal: https://github.com/NenengR/multi-agent, HEAD e3751c08f8b3f21a24fc8b7e218eebeb9186de23
Status: perbaikan lokal di workspace ini saja. Belum di push ke GitHub. Belum di install di VPS. Belum ada trading live.

## 1. Yang sudah diverifikasi langsung oleh HAMID

- Condor, branch deploy/pipeline-customizations, HEAD 8ced9726d18bb5d0a439d190c89aa51c80419503, 26 Jul 2026, pesan Fix hcnsec model routing.
- Hummingbot API, main, HEAD 7ae108f11bf20651682dbdff639a8717068c5883, 15 Okt 2026, merge PR 246 position mode.
- Semua script shell di repo Fase 1 lolos bash -n setelah patch.
- Koreksi atas laporan audit: password EMQX di installer asli adalah changeme123, bukan hummingbot-api. Password Postgres asli adalah hummingbot-api. Keduanya sudah diganti jadi variabel di Fase 1.

## 2. Temuan audit Condor, ringkas

Repo Condor punya 6 agent lengkap, signal bus berbasis file di agents/_signals, dan risk engine yang fail-closed kalau metrik tidak tersedia.

Yang belum aman:
- Dry run hanya observasi, bukan paper trading. Tidak ada fill simulasi, saldo virtual, atau PnL paper. Jangan sebut dry run sebagai paper trading.
- Tidak ada daily loss limit, padahal docstring risk.py mengklaim ada. Nilai daily PnL hanya ditampilkan, tidak dipakai sebagai gate.
- Drawdown default -1, artinya disabled. Di 4 scanner dan synthesis nilainya 100, artinya praktis tidak pernah trip.
- Tidak ada file shutdown.md di repo. Policy winddown hanya mengandalkan default kode keep_spot_close_perp.
- UI default execution_mode loop, bukan dry run.
- Start strategy memakai dict.update dangkal untuk risk_limits, jadi shutdown_drawdown_pct dari strategy bisa hilang dan jatuh ke -1 kalau UI hanya kirim 3 field.
- Template publish synthesis tidak memuat metadata.intent, metadata.conflict, dan metadata.genuine_uncertainty, padahal executor memeriksa ketiganya. Field yang hilang dibaca falsy, jadi gate konflik jadi fail-open.
- Angka risiko tidak konsisten: risk_per_trade 2 persen di strategy, 3 persen di exec_plan.py dan di rumus strategy, time limit 14400 di strategy dan 3600 di exec_plan, total_amount_quote 50 di asisten dan 100 di UI dan config.
- Leverage default trade_executor 20, maks 50. Max position total 50 USD di trade_executor, maks executor terbuka 3.
- Sinyal synthesis expires 600 detik, executor menolak sinyal di atas 5 menit.
- Tidak ada tombol stop semua pipeline. Stop harus satu per satu per agent.

## 3. Temuan audit installer dan hummingbot-api, ringkas

- Hummingbot API tidak punya switch global PAPER_MODE. Paper trading adalah per konektor, contoh binance_paper_trade, gate_io_paper_trade, kucoin_paper_trade. Konektor paper tidak bisa jadi sumber market data, harga harus dari konektor live paralel.
- Installer asli tidak pin commit, tidak ada gate paper, URL clone salah di deploy/README.md, path tidak konsisten, username heliosneo hardcode, password API, config, dan gateway disamakan, escape BROKER dan GATEWAY_PASSPHRASE salah sehingga nilai literal tersimpan, validasi secret kurang, ADMIN_USER_ID 0 bisa lolos, pola pkill MCP salah, systemd menyebut hummingbot-api.service yang tidak pernah diinstal, restart loop bisa berhenti di tengah, uninstall dengan docker compose down -v menghapus data Postgres padahal klaimnya tidak, dan langkah secrets di README bertentangan.

## 4. Yang diperbaiki di repo Fase 1 ini

File baru:
- versions.lock, berisi CONDOR_COMMIT dan HUMMINGBOT_API_COMMIT yang sudah diverifikasi di atas, plus postgres:16 dan emqx:5.
- PHASE1-REPORT.md, file ini.

Perubahan di manifest deploy:
- deploy/README.md dan README.md: clone URL diperbaiki ke https://github.com/NenengR/multi-agent, langkah secrets diperbaiki urutannya jadi sudo install -d, sudo cp, sudo chmod 600, lalu sudo nano, path diperbaiki ke /home/condor/condor-deploy/condor.
- deploy/vps/install-condor.sh: pin commit Condor dan hummingbot-api, checkout dan verifikasi rev-parse HEAD setelah clone, juga saat direktori sudah ada. Validasi require_nonempty untuk ADMIN_USER_ID, HB_API_USERNAME, HB_API_PASSWORD, CONFIG_PASSWORD, GATEWAY_PASSPHRASE, BROKER_USERNAME, BROKER_PASSWORD, POSTGRES_PASSWORD, EMQX_DASHBOARD_PASSWORD, TAILSCALE_AUTH_KEY, PAPER_MODE, dan CONDOR_ADMIN_USERNAME. Tolak ADMIN_USER_ID 0. Tolak kalau tiga password Hummingbot sama. Pisahkan CONFIG_PASSWORD dan GATEWAY_PASSPHRASE dari HB_API_PASSWORD, perbaiki escape BROKER, ganti GATEWAY_URL ke https, ganti eval dengan indirect expansion, dan teruskan PAPER_MODE ke condor .env.
- deploy/vps/env.example: tambah PAPER_MODE=true default, LIVE_TRADING_CONFIRMED=no, CONDOR_ADMIN_USERNAME, PAPER_CONNECTOR=binance_paper_trade, placeholder risk limit yang masih kosong, dan tiga password terpisah plus POSTGRES_PASSWORD dan EMQX_DASHBOARD_PASSWORD.
- deploy/vps/systemd/condor-bootstrap-pipeline.sh dan condor-restart-agents.sh: gate paper. Kalau PAPER_MODE=true, semua agent jalan dry_run dan execution_agent tidak di start. Live hanya kalau PAPER_MODE=false dan LIVE_TRADING_CONFIRMED=yes. Username heliosneo diganti variabel CONDOR_ADMIN_USERNAME. Pola pkill MCP disederhanakan ke mcp_servers. Start loop di restart diberi fallback supaya tidak berhenti di tengah.
- deploy/vps/systemd/condor-main.service: hapus hummingbot-api.service dari After, tambah Wants condor-infra.service.
- deploy/vps/systemd/condor-start-hb-api.sh: cek /health dan gagal kalau bukan 200, bukan cek root /.
- deploy/VPS_OPERATIONS.md: path ~ diganti path absolut /home/condor/condor-deploy, pola pkill disamakan, dan peringatan bahwa uninstall menghapus data DB.

Catatan jujur soal compose: password Postgres dan EMQX sekarang berasal dari secrets.env. Heredoc compose diubah jadi tanpa kutip supaya variabel mengembang saat install. Itu harus diuji di VPS test sebelum dianggap benar.

## 5. Yang belum diperbaiki, karena kodenya ada di repo lain

Perbaikan di bawah ini butuh perubahan di repo NenengR/condor, bukan di repo manifest ini. File ini hanya proposal, belum diterapkan ke repo Condor:
- Ubah default UI ke dry_run dan tambah konfirmasi sebelum loop.
- Deep merge risk_limits di start_strategy, tambah test regresi.
- Buat agents/_defaults/shutdown.md dan trade_executor shutdown.md dengan on_kill_switch flatten_all untuk live pertama.
- Tambah daily loss limit nyata dari journal.get_daily_pnl, lalu blokir tick dan panggil shutdown kalau terlampaui.
- Samakan risk_per_trade ke satu angka, dan time_limit ke satu angka.
- Wajibkan synthesis mengisi metadata.intent, metadata.conflict, dan metadata.genuine_uncertainty di setiap publish.
- Selaraskan expiry sinyal synthesis ke 300 detik.
- Turunkan leverage awal, dan tambah tombol stop semua pipeline.

## 6. Keputusan yang masih butuh master

Jangan mulai live sebelum empat hal ini diputuskan:
1. Modal live pertama, pair pertama, dan connector pertama.
2. Leverage maksimum live pertama.
3. Daily loss limit, max drawdown, dan shutdown drawdown untuk trade_executor. Usulan awal konservatif dari audit, bukan keputusan: max drawdown 5 persen, shutdown 10 persen, max position 50 USD, max executor 1, stop_after_first_fill true.
4. Apakah membuat mode paper dengan fill simulasi, atau tetap memakai dry run observasi saja lalu langsung ke live kecil dengan stop_after_first_fill true.

## 7. Langkah berikut yang disarankan

1. Master review diff di folder ini.
2. Kalau setuju, push ke branch baru, contoh phase1-paper-gate, bukan langsung ke main, lalu buat pull request.
3. Test install di VPS test dengan PAPER_MODE=true, konektor binance_paper_trade, dan market data dari konektor live paralel.
4. Baru setelah dry run terbukti, bahas angka live di bagian 6.

## 8. Batas dan hal yang belum diuji

- Installer tidak dijalankan di VPS dalam Fase 1 ini. Semua verifikasi di sini adalah bash -n dan pembacaan kode.
- Perilaku runtime pola pkill dan nilai literal di .env hasil generate hanya dinilai dari kode, dan harus diuji di VPS test paper.
- Tidak ada secret asli yang dipakai dalam audit ini. Semua password di file contoh masih kosong atau placeholder.

## 10. Fase 1.1, installer lokal non-trading, 12 Nov 2026 22:48 WIB

Garing memeriksa instalasi jam 20:43 WIB dan TIDAK menjalankan installer lama, dengan alasan yang benar: installer lama mereset dan mengaktifkan UFW, memasang dan mengautentikasi Tailscale, lalu mengaktifkan bootstrap yang memulai agent strategies, dan akan berhenti di TELEGRAM_TOKEN kosong serta preflight HCNSEC. Docker service dilaporkan inactive walau docker ps masih menampilkan container TASHI dan OptimAI.

File baru: deploy/vps/install-condor-local.sh, 353 baris, lolos bash -n.
Isinya:
- Menolak jalan kecuali PAPER_MODE=true dan LIVE_TRADING_CONFIRMED=no, dan menolak kalau ada kunci exchange di secrets.env.
- Tidak ada perubahan firewall, tidak ada Tailscale, tidak ada Telegram, tidak ada HCNSEC, tidak ada Anthropic.
- Password lokal (Postgres, EMQX, Hummingbot API, config, gateway, broker) dibuat otomatis dengan openssl rand kalau kosong, disimpan hanya di /etc/condor/secrets.env mode 600, tidak pernah dicetak atau dikirim.
- Cek docker info dulu, berhenti dengan pesan jelas kalau daemon tidak jalan, jangan restart diam-diam.
- Model Apinex OpenAI: AGENT_KEY=openai:free/deepseek-v4.1-flash, MODEL_BASE_URL=https://api.apinex.bond/v1, OPENAI_API_KEY dikosongkan, diisi nanti lewat jalur aman sebelum tick dry run pertama.
- Systemd: hanya enable dan start condor-infra dan condor-main. condor-bootstrap-pipeline di-install tapi di-disable dan di-stop, tidak ada strategi yang jalan, tidak ada executor, tidak ada order.
- Verifikasi akhir hanya /health dan status systemd, lalu laporkan ke HAMID.

## 11. Fase 1.2, bind loopback dan model HCNSEC, 13 Nov 2026 00:15 WIB

Garing memeriksa lagi jam 22:53 WIB dan TIDAK menjalankan installer lokal, dengan alasan yang benar: Condor main.py menjalankan Uvicorn di 0.0.0.0 (baris 719), Dockerfile Hummingbot API menjalankan Uvicorn di 0.0.0.0:8000 (baris 56), dan Sandbox tidak punya UFW, jadi service tidak bisa dijaga local-only. Header installer lama masih menyebut commit lama 615928. Docker unit masih inactive.
Perbaikan di install-condor-local.sh, terverifikasi di file asli hasil clone:
- Setelah clone, main.py di-patch host="0.0.0.0" jadi host="127.0.0.1", diverifikasi grep sebelum dan sesudah.
- Dockerfile di-patch "0.0.0.0" jadi "127.0.0.1" (bentuk JSON "--host", "0.0.0.0"), diverifikasi grep sebelum dan sesudah.
- API_BIND=127.0.0.1 ditambah di hummingbot-api .env.
- Pemeriksaan bind dengan ss di akhir: gagal kalau ada service yang listen di 0.0.0.0 pada port 8000, 8088, 5432, 1883, 18083, atau 8083.
- Header commit lama dihapus, diganti perintah pull latest dan catat HEAD yang di-pull, supaya tidak basi lagi.
- Model diganti atas keputusan master 13 Nov 2026 00:15 WIB: pakai API HCNSEC saja. AGENT_KEY=openai:MiniMax-M3.1-Flash, MODEL_BASE_URL=https://api.hcnsec.cn/v1. HCNSEC terverifikasi 13 Nov 2026 00:00 WIB, models 200, 3 model, chat test OK 9 detik. Apinex tidak dipakai lagi untuk Condor ini. Kunci HCNSEC tidak dikirim lewat email, diisi lewat jalur aman sebelum tick dry run pertama.
Jadwal master: trade seharusnya mulai jam 00:00 WIB 13 Nov 2026, sudah lewat. Blocker yang tersisa setelah revisi ini: hasil install Garing, tick dry run 1 dengan HCNSEC, preview baru, dan konfirmasi master sebelum live.

## 12. Fase 1.3, secrets terpisah dan web API tanpa Telegram, 13 Nov 2026 04:10 WIB

Docker sudah pulih 13 Nov 2026: Garing force-stop dua container dan dockerd yang macet (PID 10115 sejak 11 Nov) atas persetujuan Pakle, docker.service aktif, Docker 29.1.3, lalu TASHI dibuat ulang tag ghcr.io/tashigit/tashi-depin-worker:0 dengan auth volume lama, dan OptimAI Crawl4AI healthy. TASHI log bonded dan tersambung ke orchestrator, belum ada tanda earning/eligible. OptimAI dan Teneo active.
Dua blocker Phase 1.2 yang dilaporkan Garing jam 03:51 WIB, keduanya dijawab di revisi ini:
1. Secrets file: installer lama menambahkan delapan password lokal ke /etc/condor/secrets.env, padahal Pakle hanya mengizinkan tiga nilai. Perbaikan: password lokal dibuat di file terpisah /etc/condor/local-secrets.env (chmod 600), dan installer GAGAL kalau file kanonis tidak berisi tepat tiga nilai (PAPER_MODE=true, LIVE_TRADING_CONFIRMED=no, CONDOR_ADMIN_USERNAME=admin) atau mengandung kunci credential apa pun. Tidak perlu SECRETS_FILE override, jalankan installer seperti biasa, file kanonis tidak pernah ditulis.
2. Telegram: main.py selalu membangun Telegram Application dengan TELEGRAM_TOKEN, jadi condor-main tidak bisa start tanpa token asli. Perbaikan, terverifikasi dari kode Condor: instalasi lokal TIDAK menjalankan main.py sama sekali, melainkan hanya FastAPI web app (condor.web.app:create_app) lewat unit baru condor-web.service, bind 127.0.0.1:8088. create_app tidak butuh Telegram token, dan condor/web/auth.py menandatangani JWT web dari WEB_JWT_SECRET atau secret acak di config.yml, bukan dari TELEGRAM_TOKEN. Bot Telegram nonaktif di mode ini, API dan infra Condor tidak terpengaruh, strategi tetap tidak pernah di-start, bootstrap tetap disabled.

## 17. Fase 1.8, segarkan salinan deploy lama dan buktikan script terpasang, 13 Nov 2026 06:17 WIB

Preflight Garing 06:10 WIB (id 1a1d2075030d7a96): repo fast-forward ke 06c71c5, patch loopback idempotent lulus, kedua file lokal sudah 127.0.0.1, Compose lolos parse (CMD-SHELL, start_period 60 detik). Reinstall BELUM dijalankan, blocker baru: installer memakai /home/condor/condor-deploy kalau direktori itu sudah ada, tapi direktori yang ada masih commit lama 1759fdb, dan script di sana maupun di /usr/local/bin/condor-start-hb-api.sh masih memeriksa /health, jadi langkah 7 tidak akan memasang cek GET / seperti yang dijelaskan. Penyebab terkonfirmasi dari kode (baris 255-262): blok copy hanya berjalan kalau DEPLOY_DIR belum ada; kalau sudah ada, copy dilewati lalu INSTALL_ROOT dipindah ke salinan lama, sehingga semua file yang dipasang langkah 7 berasal dari commit 1759fdb. Kesalahan desain dari Fase 1.1 yang baru ketahuan di rerun.
Perbaikan Fase 1.8: kalau DEPLOY_DIR sudah ada, segarkan hanya folder deploy/ dari clone baru (cp -a deploy/.), jangan sentuh checkout condor/hummingbot-api beserta patch loopback lokalnya, dan jangan sentuh config hasil generate. Installer juga mencetak commit asal file-file itu. Langkah 7 sekarang memverifikasi dengan grep bahwa script terpasang mengandung cek GET / dan tidak lagi mengandung 8000/health, dan GAGAL kalau tidak terbukti. Dites dengan simulasi: salinan deploy lama disegarkan ke versi baru, checkout subproject dan .env hasil generate tidak berubah (md5 cocok), verifikasi grep lolos pada script baru dan menolak script lama, bash -n lolos.

## 16. Fase 1.7, patch loopback idempotent, 13 Nov 2026 06:04 WIB

Audit Garing 05:56 WIB (id 1a1d1fa46c9ae30b): commit f8ef5bb ditarik, Compose lolos parser (CMD-SHELL, start_period 60 detik, bind loopback benar). Reinstall BERHENTI langkah 2b/8: FAIL Condor main.py does not contain the expected 0.0.0.0 bind, do not guess a different patch, report this. Penyebab: checkout lama sudah berisi patch lokal main.py dan Dockerfile ke 127.0.0.1, script hanya menerima pola asal 0.0.0.0, jadi gagal sebelum menulis ulang Compose atau memasang unit. condor-start-hb-api.sh baru belum terpasang, condor-infra masih failed karena script aktif masih mengecek /health. apt-get tidak memasang paket baru, script sempat mencoba pasang uv. Docker aktif, TASHI jalan, OptimAI sehat, Teneo aktif, Postgres sehat, broker unhealthy, Condor Web active/200, Hummingbot root 200 dan /health 404, main/bootstrap disabled, secrets.env dan credential files tetap 0600, HCNSEC key kosong, tidak ada tick/trading. Garing minta patch loopback idempotent untuk kedua file (terima 127.0.0.1 sebagai sudah benar, berhenti hanya kalau keduanya tidak ditemukan) dan pastikan rerun memasang ulang script startup GET /.
Perbaikan Fase 1.7: langkah 2b sekarang idempotent untuk kedua file: patch 0.0.0.0 kalau masih public, lewati kalau sudah 127.0.0.1, gagal hanya kalau keduanya tidak ditemukan. Dites pada file asli dari commit pin: run 1 (fresh) kedua file ter-patch exit 0, run 2 (rerun pada file yang sudah ter-patch, kasus persis Garing) keduanya dilewati exit 0, run 3 (tidak ada pola) gagal exit 1, jadi fail-closed tetap terjaga. Rerun kemudian lanjut ke langkah 3 (tulis ulang Compose) dan langkah 7 (pasang ulang condor-start-hb-api.sh dengan cek GET /).

## 15. Fase 1.6, perbaiki syntax healthcheck broker dan start_period sungguhan, 13 Nov 2026 05:49 WIB

Audit Garing 05:44 WIB (id 1a1d1eef5ee16d6c): reinstall tidak dijalankan karena ketidaksesuaian di f7630da. HB API GET / 200, /health 404, condor-web active 200, condor-infra masih failed karena script startup yang terpasang masih mengecek /health (perbaikan GET / sudah ada di repo, baru aktif setelah reinstall). Broker jalan tapi unhealthy: healthcheck compose memanggil EMQX_HEALTHCHECK=1 emqx ping sebagai executable literal, Docker lapor executable file not found in $PATH; tes manual Garing membuktikan broker sehat (emqx ctl status node started, emqx ping pong). KESALAHAN HAMID: start_period 60s hanya ada sebagai komentar di Fase 1.5, bukan properti YAML.
Perbaikan Fase 1.6: test healthcheck diganti ke ["CMD-SHELL", "EMQX_HEALTHCHECK=1 emqx ping"] supaya assignment env ditafsirkan shell, dan properti YAML start_period: 60s benar-benar ditambahkan. Verifikasi kali ini: compose yang dihasilkan installer di-parse dengan YAML parser dan dicek propertinya sebelum push, supaya perbaikan komentar saja tidak lolos lagi. Catatan Garing soal Erlang cookie default EMQX yang tidak aman dicatat, tidak diubah pada fase ini karena install loopback-only.

## 14. Fase 1.5, perbaiki cek /health Hummingbot dan kejujuran installer, 13 Nov 2026 05:35 WIB

Laporan install Garing 05:24 WIB (id 1a1d1dcf3f80f5d7): installer exit 0 di HEAD 1759fdb, secrets.env tetap 3 nilai mode 0600, semua file credential mode 0600, HCNSEC route terpasang tapi OPENAI_API_KEY kosong, Garing belum menambahkan API key yang Pakle kirim dan belum menjalankan model tick. Yang gagal: Hummingbot GET /health 404, condor-infra failed, broker container unhealthy. Yang jalan: condor-web active dan loopback HTTP 200, Docker aktif, TASHI jalan, OptimAI healthy, Teneo aktif, Nginx tidak terpasang, port 80 tertutup. Tidak ada Gate.io, strategy, executor, order, atau trading.
Diagnosis HAMID, terverifikasi dari source pin 7ae108f: hummingbot-api v1.0.1 TIDAK PUNYA route /health sama sekali, hanya GET / yang mengembalikan status running. Jadi 404 itu salah cek dari Fase 1, bukan servicenya mati. Script condor-start-hb-api.sh adalah ExecStartPost condor-infra, jadi exit 1 di sana membuat condor-infra failed.
Perbaikan Fase 1.5: cek GET / (200) di condor-start-hb-api.sh dan di installer, step 8 installer sekarang FAIL kalau condor-infra atau condor-web tidak active (sebelumnya hanya warn, sehingga install bisa exit 0 dengan infra mati), healthcheck broker ditambah start_period 60 detik karena boot pertama EMQX lambat. Penyebab broker unhealthy tidak ditebak; Garing diminta kirim docker logs dan output emqx ctl status.

## 13. Fase 1.4, izin file credential dan hapus nginx, 13 Nov 2026 04:56 WIB

Garing mengaudit lagi jam 04:19 dan 04:22 WIB dan TIDAK menjalankan installer, dengan dua temuan yang benar:
1. docker-compose.yml berisi POSTGRES_PASSWORD dan EMQX_DASHBOARD_PASSWORD, dan dengan root umask 0022 file baru akan bermode 0644, terbaca semua pengguna lokal. Installer juga menyalin kredensial ke konfigurasi runtime lain.
2. Installer memasang nginx-light, yang belum ada di host. Paket itu meng-enable nginx.service dan memasang default site di 0.0.0.0:80 dan [::]:80. Setup yang disetujui adalah local-only, Condor web sudah loopback 127.0.0.1:8088.
Perbaikan di install-condor-local.sh:
- umask 077 di awal script, chmod 600 eksplisit pada docker-compose.yml, dan audit akhir yang gagal kalau salah satu file credential (local-secrets, compose, hummingbot-api .env, condor config.yml, condor .env) tidak bermode 600.
- nginx-light dihapus dari daftar apt, karena tidak dipakai Condor. Cek akhir gagal kalau nginx enabled atau active, dan cek bind ss juga mencakup port 80.

## 9. Keputusan master 12:35 WIB 12 Nov 2026

Master setuju paket konservatif, dan minta cek diff dulu di chat sebelum push.
Nilai yang disetujui dan sudah dimasukkan ke deploy/vps/env.example:
- MAX_POSITION_SIZE_QUOTE=50
- MAX_OPEN_EXECUTORS=1
- MAX_DRAWDOWN_PCT=5
- SHUTDOWN_DRAWDOWN_PCT=10
- STOP_AFTER_FIRST_FILL=true
Masih terbuka: MAX_DAILY_LOSS_QUOTE, modal live pertama, pair pertama, connector pertama, leverage maksimum, RISK_PER_TRADE_PCT.
Usulan konservatif yang belum dikonfirmasi: risk 2 persen, leverage maks 10x.

## 18. Fase 1.9, patch api_key OpenAI dan arahkan tick ke jalur OpenAI, 13 Nov 2026 08:40 WIB

Diagnosis HAMID 08:25-08:40 WIB (master curiga pengaturan ACP, "sekarang pakai nya OPENAI bukan Claude Code"), terverifikasi dari source pin Condor 8ced972:
1. Tick tidak pernah pakai OpenAI. agent_key market_screener jatuh ke claude-code:hcnsec dari agents/market_screener/AGENT.md (strategy frontmatter agent_key null, POST start hanya kirim execution_mode). Tidak ada satu baris kode pun di repo yang membaca AGENT_KEY atau MODEL_BASE_URL dari env (grep seluruh repo 0 hasil), jadi semua ganti model di condor/.env (HCNSEC, lalu FortyTwo) tidak mengubah apa pun yang dijalankan tick.
2. Jalur Claude ACP menggantung tanpa timeout. resolve_acp(claude-code:hcnsec) menjalankan claude-agent-acp dan memetakan kredensial dari ANTHROPIC_API_KEY_HCNSEC dan ANTHROPIC_BASE_URL_HCNSEC, installer lokal tidak pernah mengisi keduanya. ACPClient.start() kirim handshake initialize + session/new lewat send_request yang menunggu future TANPA timeout; timeout 600 detik di engine hanya membungkus prompt stream, BUKAN start(). Kalau subprocess tidak menjawab handshake, tick menggantung selamanya: RUNNING, tick_count=0, tanpa error. Persis gejala kedua tick (HCNSEC 27 menit, FortyTwo 15 menit).
3. Kalaupun diarahkan ke jalur OpenAI, api_key di sana hardcoded "not-needed" (baris 380 dan 391 pydantic_ai_client.py), bukan OPENAI_API_KEY dari env, jadi request ke FortyTwo/HCNSEC akan 401.
Perbaikan di install-condor-local.sh, step 2c baru (setelah patch loopback 2b): patch idempotent pada condor/condor/acp/pydantic_ai_client.py, hanya cabang openai+base_url, supaya api_key membaca OPENAI_API_KEY dari env dan raise RuntimeError jelas kalau kosong. Cabang ollama/lmstudio tetap "not-needed" karena server lokal mengabaikan kunci. Patch diuji pada file pin asli dalam 3 kasus: file segar ter-patch dan lolos py_compile, rerun di-skip (idempotent), blok rusak gagal exit 1 (fail-closed). Tick diarahkan ke jalur OpenAI lewat agent_key + model_base_url di config POST start (engine membaca config agent_key dulu). Bash syntax dicek dengan bash -n sebelum push.

## 19. Fase 2.0, perkecil prompt screener (candle cap, routine allowlist, .env preserve), 13 Nov 2026 19:23 WIB
Keputusan master 19:23 WIB: bangun perbaikan perkecil prompt dulu, baru retry FortyTwo. Latar: tick FortyTwo gagal 400 context_length_exceeded (prompt di atas 262.144 token); tick HCNSEC MiniMax jalan tapi timeout 231,4 detik (bukan 600 detik, jadi bukan batas timeout Condor; prompt tick itu KECIL, tanpa candles, 10 tool call; penyebabnya latensi model/gateway HCNSEC, TTFT 64,3 detik untuk prompt 22 ribu token diukur dari VM HAMID).
Ukur HAMID dari kode pin Condor 8ced972 (tiktoken cl100k): prompt statis hanya ~7.000 token (AGENT.md 1.007, strategy.md 2.023, base prompt 587, 5 schema tool yang diizinkan 2.478). Allowlist tool SUDAH bekerja (_prepare_tools memfilter sebelum kirim). Yang membengkak adalah HASIL tool call yang menumpuk selama tick. Tersangka utama candles: tool default days=30 (720 candle per panggilan, ~20 ribu token sebagai tabel; 10 pair ~200 ribu token). CACAT: strategy.md menyuruh limit=24, tapi get_market_data/get_candles TIDAK punya parameter limit, hanya days (default 30). TEMUAN LAIN: scan_universe tidak bisa dipakai karena manage_routines tidak ada di allowlist 5 tool market_screener, padahal strategy.md menjadikan routine itu jalur utama (1 panggilan, tabel ringkas).
Perbaikan di install-condor-local.sh (patch installer, pola sama seperti 2b/2c: idempotent, fail-closed, py_compile):
- Step 2d: get_candles di mcp_servers/hummingbot_api/tools/market_data.py dapat parameter limit, dan ada cap absolut 48 record per panggilan (720 jadi paling banyak 48, ~1.500 token).
- Step 2e: get_market_data di mcp_servers/hummingbot_api/server.py dapat parameter limit dan meneruskannya ke get_candles, sehingga instruksi limit=24 di strategy.md akhirnya bekerja. strategy.md tidak perlu diubah.
- Step 2f: manage_routines masuk allowlist tools di agents/market_screener/AGENT.md, supaya agent bisa pakai routine scan_universe. CATATAN: allowlist bekerja per nama tool, jadi agent juga mendapat aksi lain dari tool itu (list/describe/create/edit/delete routine). Strategy hanya menginstruksikan run; ini agent screener kita sendiri dalam eksperimen dry-run, dan routine yang dijalankan (scan_universe) sudah direview kodenya. Kalau routine gagal saat jalan, strategy fallback ke get_market_data per pair.
- Step 6 (.env preserve, kandidat Fase 1.10): installer tidak lagi menimpa AGENT_KEY / MODEL_BASE_URL / OPENAI_API_KEY di condor/.env pada rerun kalau file sudah mengisinya; hanya tulis default (HCNSEC) kalau kosong/tidak ada. Ini memperbaiki cacat yang terlihat saat eksekusi Fase 1.9 (rerun mengosongkan kunci dan memaksa restore manual).
Pengujian (seperti Fase 1.9, pada file pin asli): file segar ter-patch dan lolos py_compile, rerun di-skip (md5 tidak berubah), blok rusak gagal exit 1. Satu pelajaran dari pengujian ini: pemeriksaan substring polos bisa lolos pada file yang baris terakhirnya hanya ditambahi teks, karena blok lama tetap cocok sebagai prefix. Semua blok patch Fase 2.0 sekarang diakhiri newline (tanda kutip penutup di baris sendiri), sehingga korupsi tempel di ujung blok pun gagal; diuji pada 7 anchor (semua gagal exit 1). Bash syntax dicek dengan bash -n sebelum push.
Yang TIDAK diubah: batas timeout 600 detik (SDK via LOCAL_MODEL_READ_TIMEOUT dan engine asyncio.timeout) tetap, karena timeout 231 detik bukan dari batas itu; menaikkannya tidak akan membantu tick HCNSEC.
