bash
# Pulisce i file di build del progetto
flutter clean

# Prova a scaricare di nuovo le dipendenze
flutter pub get

# Se il problema persiste, ripara la cache di sistema
flutter pub cache repair
