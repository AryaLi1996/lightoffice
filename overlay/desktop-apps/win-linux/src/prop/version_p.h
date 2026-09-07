#ifndef VERSION_PRIVATE_H
#define VERSION_PRIVATE_H

/*
 * LightOffice branding override.
 *
 * version.h includes this file last (guarded by RC_COMPILE_FLAG), which is the
 * vendor hook upstream provides for rebranding — the same mechanism the __NCT
 * build uses. Redefining the strings here re-brands both the Windows VERSIONINFO
 * resource and the in-app About dialog without touching upstream sources.
 */

#undef VER_COMPANYNAME_STR
#undef VER_LEGALCOPYRIGHT_STR
#undef VER_COMPANYDOMAIN_STR
#undef ABOUT_COPYRIGHT_STR
#undef VER_FILEDESCRIPTION_STR
#undef VER_INTERNALNAME_STR
#undef VER_PRODUCTNAME_STR
#undef VER_ORIGINALFILENAME_STR
#undef VER_LEGALTRADEMARKS1_STR
#undef VER_LEGALTRADEMARKS2_STR

#define VER_COMPANYNAME_STR         "LightOffice Technologies Co., Ltd.\0"
#define VER_LEGALCOPYRIGHT_STR      "(c) LightOffice Technologies Co., Ltd. " TO_STR(COPYRIGHT_YEAR) ". All rights reserved.\0"
#define VER_COMPANYDOMAIN_STR       "lightoffice.internal\0"
#define ABOUT_COPYRIGHT_STR         VER_LEGALCOPYRIGHT_STR
#define VER_FILEDESCRIPTION_STR     "LightOffice Desktop Editors\0"
#define VER_INTERNALNAME_STR        "LightOffice\0"
#define VER_PRODUCTNAME_STR         "LightOffice\0"
#define VER_ORIGINALFILENAME_STR    "lightoffice.exe\0"
#define VER_LEGALTRADEMARKS1_STR    "All Rights Reserved\0"
#define VER_LEGALTRADEMARKS2_STR    VER_LEGALTRADEMARKS1_STR

/*
 * Upstream still ships the AGPL notice that requires attribution to the
 * original authors; the override above changes the vendor identity of this
 * build only and does not remove upstream's own copyright headers.
 */

#endif // VERSION_PRIVATE_H
