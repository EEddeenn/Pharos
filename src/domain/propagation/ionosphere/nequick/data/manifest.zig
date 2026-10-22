const provenance = @import("base/provenance");

pub const ccir = [12]provenance.Blob{
    provenance.blob(@embedFile("ccir11.txt"), 47158, "9e0c994b14a52e227516a3179a2a108c70651b075b99813cc9c0f80f659d7866"),
    provenance.blob(@embedFile("ccir12.txt"), 47158, "0a92025c96b52be8d76423e711a25a4dac86d214cf7a97c8df52534839b1951d"),
    provenance.blob(@embedFile("ccir13.txt"), 47158, "3f5968dcb45f57ee4173e27afc9628f7f0dfb13e67a895110797ef1dbf0cb89d"),
    provenance.blob(@embedFile("ccir14.txt"), 47158, "fe8dbff8b0692f6475e1cd395320385e35ebf6f9e19b2bea8a4fd43233845388"),
    provenance.blob(@embedFile("ccir15.txt"), 47158, "ea31c03eaf7ff33a165824e7c5ce1d0d05fedaf4699f9965abb41ac9823f8826"),
    provenance.blob(@embedFile("ccir16.txt"), 47158, "b422270403b37e522a43da3b7f196932339e85c89b4c5d88902a8c4a889dd452"),
    provenance.blob(@embedFile("ccir17.txt"), 47158, "8c0042c5c4cb08ea9d423efad233b1f0d6025993d19e220e41daf2f47f60103a"),
    provenance.blob(@embedFile("ccir18.txt"), 47158, "302633e8002accf73af4516fe43a3b44ec6e056fe6c079396d4cd3744d341221"),
    provenance.blob(@embedFile("ccir19.txt"), 47158, "c007d7767e8eb37f6bd09fb3b20bb8616925b34194c9460843ab915589e741d9"),
    provenance.blob(@embedFile("ccir20.txt"), 47158, "9c91161c584e8451320175f8b3596b84d952753746173fe1a049146b476f9699"),
    provenance.blob(@embedFile("ccir21.txt"), 47158, "824b5bfdd3cee884e3bee8cf1e6cde37454c230d00fc880227e68868b1bd261d"),
    provenance.blob(@embedFile("ccir22.txt"), 47158, "8c55602384d59282fccf9c2234aeea32d32960360f8b6b07840fb02afdb28c18"),
};

pub const modip = provenance.blob(@embedFile("modipNeQG_wrapped.txt"), 12911, "9dd96a1a6a39d8305dc3e9dabf3fbd0e00ca4d9021ffcf4e7741da80abf2d84f");
