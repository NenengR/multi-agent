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
