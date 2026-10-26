// Indonesian interface option. Static template text is translated by exact-match lookup when a template
// is cloned (see component-loader.js); text built in JavaScript (toasts, errors, admin) stays in English.
// shortcut: partial coverage (shell, wall, note card, composer), add strings to ID as other views need them.
import { local } from "./utils.js";

const ID = {
  "Campus Sticky Wall home": "Beranda Campus Sticky Wall", "Menu": "Menu", "Main": "Utama",
  "Wall": "Dinding", "Promotions": "Promosi", "Leaderboard": "Papan Peringkat", "News": "Berita", "Support us": "Dukung kami",
  "Switch to dark mode": "Ganti ke mode gelap", "+ Post a note": "+ Pasang catatan", "Sign in": "Masuk", "Account": "Akun", "Sign out": "Keluar",
  "Something went wrong": "Terjadi kesalahan", "This page could not be loaded.": "Halaman ini tidak bisa dimuat.", "Try again": "Coba lagi",
  "Back to the wall": "Kembali ke dinding", "Page not found": "Halaman tidak ditemukan", "That page doesn’t exist.": "Halaman itu tidak ada.",
  "Go back to the wall.": "Kembali ke dinding.", "Sign in required": "Perlu masuk", "This feature is available to registered accounts.": "Fitur ini hanya untuk akun terdaftar.",
  "Sign in or create an account": "Masuk atau buat akun", "Cancel": "Batal", "OK": "OK",
  "Campus Sticky Wall · made for students": "Campus Sticky Wall · dibuat untuk mahasiswa", "Privacy": "Privasi", "Terms": "Ketentuan", "Advertise": "Pasang iklan", "Contact": "Kontak",
  "Top notes": "Catatan teratas", "The Wall": "Dinding",
  "Notes from students, pinned by students. Anyone can post — you choose what you pay (from Rp2.500).": "Catatan dari mahasiswa, ditempel oleh mahasiswa. Siapa saja boleh memasang — kamu yang menentukan harganya (mulai Rp2.500).",
  "Open this campus’s page →": "Buka halaman kampus ini →", "Search notes…": "Cari catatan…", "Search notes": "Cari catatan", "Filter & sort": "Filter & urutkan",
  "Sort": "Urutkan", "Newest": "Terbaru", "Most voted": "Suara terbanyak", "Colour": "Warna", "All colours": "Semua warna",
  "Yellow": "Kuning", "Pink": "Merah muda", "Blue": "Biru", "Green": "Hijau", "Orange": "Oranye", "Purple": "Ungu",
  "No notes here yet.": "Belum ada catatan di sini.", "Be the first to post one!": "Jadilah yang pertama memasang!", "Load more notes": "Muat catatan lainnya",
  "Click to enlarge": "Klik untuk memperbesar", "Contains media": "Berisi media", "Vote for this note": "Beri suara untuk catatan ini",
  "Bookmark this note": "Simpan catatan ini", "Share this note": "Bagikan catatan ini", "Share": "Bagikan", "Report this note": "Laporkan catatan ini", "Report": "Laporkan",
  "Why are you reporting this note?": "Mengapa kamu melaporkan catatan ini?", "Spam or advertising": "Spam atau iklan", "Harassment or bullying": "Pelecehan atau perundungan",
  "Hate speech": "Ujaran kebencian", "Sexual content": "Konten seksual", "Shares someone’s personal information": "Membagikan data pribadi orang lain",
  "Scam or fraud": "Penipuan", "Something else": "Lainnya", "Details (optional)": "Rincian (opsional)",
  "Post a sticky note": "Pasang catatan tempel", "No account needed.": "Tanpa akun.", "You choose how much you pay to publish": "Kamu menentukan berapa yang dibayar untuk menayangkan",
  "— anything from": "— mulai dari", "upwards.": "ke atas.", "Your note": "Catatanmu", "Write something for your campus…": "Tulis sesuatu untuk kampusmu…",
  "Name shown on the note": "Nama yang tampil di catatan", "Leave empty to post as Anonymous": "Kosongkan untuk tampil sebagai Anonymous",
  "Optional. Empty = “Anonymous”. Plain text only: never a link, never tied to an account. Names of registered members, links and @handles are not allowed.": "Opsional. Kosong = “Anonymous”. Teks biasa saja: bukan tautan dan tidak terhubung ke akun. Nama anggota terdaftar, tautan, dan @handle tidak diperbolehkan.",
  "How much do you want to pay to publish? (Rp)": "Berapa yang ingin kamu bayar untuk menayangkan? (Rp)", "Quick amounts": "Nominal cepat",
  "Digits only (dots are fine, e.g. 25.000).": "Hanya angka (titik boleh, mis. 25.000).", "Note colour": "Warna catatan",
  "Decorations (optional)": "Dekorasi (opsional)", "Loading decorations…": "Memuat dekorasi…", "Stickers, stamps and badges": "Stiker, cap, dan lencana",
  "Social link (optional)": "Tautan sosial (opsional)", "Instagram, X, TikTok, LinkedIn, GitHub, YouTube, Facebook or Threads.": "Instagram, X, TikTok, LinkedIn, GitHub, YouTube, Facebook atau Threads.",
  "Photos, GIFs or videos (optional)": "Foto, GIF, atau video (opsional)", "Free post and promo code": "Pos gratis dan kode promo", "Promo code": "Kode promo", "Apply": "Pakai",
  "Referral credits": "Kredit referral", "Order summary": "Ringkasan pesanan", "Your publication price": "Harga penayanganmu", "Decorations": "Dekorasi", "Promo": "Promo",
  "Credits": "Kredit", "Total due": "Total bayar", "Final amounts are calculated by our server before payment.": "Jumlah akhir dihitung oleh server kami sebelum pembayaran.",
  "What we can and can’t see": "Apa yang bisa dan tidak bisa kami lihat", "Public:": "Publik:", "We don’t keep:": "Tidak kami simpan:", "Still visible:": "Tetap terlihat:",
  "Continue to payment": "Lanjut ke pembayaran",
};

export const lang = local.get("csw.lang", "en") === "id" ? "id" : "en";
if (typeof document !== "undefined") document.documentElement.lang = lang;

export function setLang(next) {
  local.set("csw.lang", next === "id" ? "id" : "en");
  window.location.reload();
}

const tr = (s) => {
  const key = s.trim().replace(/\s+/g, " ");
  return ID[key] ? s.replace(s.trim(), ID[key]) : s;
};

/** Translate a cloned template fragment in place. No-op for English. */
export function translate(root) {
  if (lang !== "id") return root;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(); n; n = walker.nextNode()) if (n.nodeValue.trim()) n.nodeValue = tr(n.nodeValue);
  for (const el of root.querySelectorAll("[placeholder],[aria-label],[title]")) {
    for (const a of ["placeholder", "aria-label", "title"]) if (el.hasAttribute(a)) el.setAttribute(a, tr(el.getAttribute(a)));
  }
  return root;
}
