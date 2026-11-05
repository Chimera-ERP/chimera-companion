# Asociere ERP prin PIN

În ERP: **Administrare → Dispozitive → Companion-uri → Înrolează Companion**
(`/settings/devices/companions`). Alege locația și generează PIN-ul; este necesar
`manage_devices`.

În Companion, primul pas cere direct PIN-ul de șase cifre și folosește
`https://chimeraerp.ro`. Pictograma de informații explică traseul din ERP.
În același dialog, **Ești client Enterprise sau self-hosted?** afișează câmpul pentru adresa
HTTPS a companiei. Scurtătura apare și după trei refuzuri explicite de PIN
(HTTP400) de la serverul implicit; erorile de rețea, limitările și alte răspunsuri
nu sunt numărate drept PIN greșit. Schimbarea adresei șterge PIN-ul din formular.
Nu există căutare automată a PIN-ului pe alte servere și nu se urmează redirecturi.

PIN-ul expiră după 10 minute, se consumă atomic o singură dată și este separat de
PIN-urile POS. Asocierea nu cere QR, login sau passkey de operator. Tokenul și
locația sunt păstrate în FlutterSecureStorage și restaurate la redeschidere.
Cererea semnată păstrează identitatea încercării pentru aceeași adresă/PIN;
reîncercarea este explicită. Nu se șterg identitatea, comenzile sau configurația
hardware la schimbarea profilului de utilizare.

Sub PIN, destinația implicită apare ca **Chimera Cloud**, cu pictogramă cloud.
Adresa tehnică rămâne `https://chimeraerp.ro`; serverele proprii folosesc aceeași
validare HTTPS și același protocol de înrolare.

## Pașii de configurare

1. PIN și confirmarea locației asociate.
2. **În fața clientului**, **În producție** sau **Personalizat**.
3. Aplicația și echipamentele potrivite: front oferă POS, casă, plată, cântar și
   ecran client; producția oferă KDS/PDS, cântar, imprimantă de producție și tastatură custom;
   personalizat expune toate opțiunile. Alegerea profilului ghidează configurarea,
   nu instalează aplicațiile POS/KDS/PDS.
4. Pregătirea automată a conexiunii. Adresa LAN, Wi-Fi, diagnostic, CSR și importul
   de certificat se află în **Avansat**. Terminarea animației nu confirmă TLS;
   doar serviciul existent de configurare/validare permite continuarea.
5. Echipamentele selectate și verificarea finală. Cele opționale pot fi amânate.

Identificatorii etapelor vechi rămân stabili; alegerile noi sunt salvate în
`setup_profile_v1` cu `version:2`, `audience`, `profile` și `devices`. Profilurile
vechi POS/KDS/PDS își păstrează echipamentele implicite. Configurația fizică
existentă nu este ștearsă dacă un echipament este deselectat în wizard.

Tastatura custom are ID-ul nou10, fără renumerotarea etapelor existente.
Pasul reutilizează `ConsolePage` și serviciul Ulanzi partajat al aplicației.
Intrarea în pas nu scanează și nu conectează USB automat; căutarea, conectarea
și proba pictogramelor sunt acțiuni explicite. Se poate continua mai târziu.
Selecțiile version2 salvate rămân intacte; noile valori implicite KDS/PDS includ
tastatura. Integrarea operațiunilor PDS nu este extinsă prin acest pas de hardware.

## Aspect și navigare

Fundalul principal este OLED black, cu accente albastre comune Forui/Material.
„Înapoi” se află în bara de sus; acțiunea principală rămâne jos, separată, cu
minimum56px înălțime. Wizardul nu afișează un total anticipat de pași: traseul
se modifică după aplicație și echipamente. Bara laterală arată etapele efective.
Explicațiile de rețea, CSR, proxy, hostname și certificat Viva se deschid din
butoane cu „i”. Validarea și mesajele de eroare nu sunt ascunse de aceste butoane.

## Animații

Sursele originale RML sunt în `design/companion-motion/scene.rml`; exportul Rive
și imaginile de rezervă sunt în `assets/motion/`. Cele14 scene au compoziții distincte pentru PIN, rol, rețea și fiecare periferic
(casă, terminal, cântar, imprimantă, ecran client, tastatură custom), plus splash, confirmare și
atenție. Splash-ul folosește logo-ul local Chimera, inclus și în pornirea nativă
Android; nu se adaugă un timp artificial de așteptare. Scenele reflectă pasul și
starea paginii, fără procente fictive. Încărcarea animației nu blochează
formularul. Runtime-ul și proveniența sunt documentate în
[vendor-provenance.md](vendor-provenance.md#rive).

Scena wizardului rămâne montată la navigare și în afara zonei vizibile de scroll.
Fișierul Rive este decodat o singură dată în arborele aplicației. Tranzițiile
combină două artboard-uri vizibile; nu se mai înlocuiește un PNG complet cu un
cadru transparent. Pauza aplicației păstrează controllerul existent. În pasul de
selecție, wrapper-ele perifericelor reflectă exact selecția, fără repornirea
buclelor; fără selecție nu apar echipamente. Eroarea de conexiune arată un RJ45
cu opt contacte și port Ethernet.

Cu Rive CLI1.9.0:

```sh
rive design/companion-motion --verify
rive inspect design/companion-motion --json
rive design/companion-motion --artboard=welcome --screenshot=/tmp/companion.png --advance=160
rive design/companion-motion --publish=local --output-dir=../../assets/motion
```

Proiectul este legat în `rive.yaml` de fișierul Rive autorizat.
Exportul local cere autentificare Rive; încărcarea în cont și publicarea unui
site sunt acțiuni distincte. Nu publica automat din procesul de build al APK-ului. Exportul curent semnalează
brandingul Rive al planului Free; acesta ține de drepturile contului, nu este
eliminat sau ascuns în aplicație.
Pentru testele native Rive pe macOS, pregătește biblioteca oficială o dată cu
`dart run rive_native:setup --platform macos`, apoi `flutter test`.

Identitatea are rolul `companion`, fără permisiunile POS. Revocarea accesului și
permisiunile hardware rămân în serviciile existente. În dezvoltare pe Android,
un ERP Enterprise trebuie să fie accesibil prin HTTPS, nu `localhost` de pe Mac.
