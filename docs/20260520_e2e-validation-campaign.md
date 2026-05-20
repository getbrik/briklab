# Rapport de campagne -- Validation E2E Brik (briklab)

> Campagne du 2026-05-20. Runtime brik teste : **0.6.0**. Lab : briklab
> (GitLab + Jenkins + Gitea + Nexus + runner + k3d). Objectif : rejouer un
> sous-ensemble representatif des scenarios E2E sur les deux plateformes,
> analyser chaque etape (actual vs expected) et collecter tous les ecarts.
>
> Statut : **aucune correction de code appliquee** -- ce document est le
> livrable d'analyse. Les correctifs proposes (section 6) attendent
> arbitrage.

---

## 1. Synthese

| Plateforme | Scenarios | Resultat brut | Apres classification |
|---|---|---|---|
| GitLab (session precedente) | 19 | 16 PASS / 3 FAIL | 0 FAIL brik reel -- 1 bug brik latent, 2 infra |
| Jenkins (cette session) | 16 | 14 PASS / 1 FAIL / 1 faux-PASS | 16/16 PASS effectifs apres resolution course parametres |

Conclusion : **aucun bug du runtime brik propre a une plateforme**. Les seuls
FAIL constates sont (a) de l'infra-lab cote GitLab, (b) une course
d'enregistrement de parametre cote harness Jenkins, et (c) un bug planner
partage qui ne se manifeste que sur GitLab faute de diff non vide cote
Jenkins.

## 2. Perimetre teste

Sous-ensemble representatif : minimal + complete + un deploy + plan-driven +
scenarios d'erreur, sur les deux plateformes.

- **GitLab** (session precedente) : groupes A, C, H, I + node-deploy, 19 scenarios.
- **Jenkins** (cette session) : groupes A, C, H (13 scenarios) + `--only node-deploy`
  + `--only node-plan-tag` + `--only error-deploy`.

Note : le groupe `I` (`node-plan-*`) n'existe pas dans `jenkins-suite.sh` et
`error-deploy` est mal classe par le mapping de groupes (cf. HARN-2, HARN-4) ;
ces deux scenarios ont donc ete lances explicitement en `--only`.

## 3. Resultats Jenkins detailles

| Scenario | Build | Verdict | Note |
|---|---|---|---|
| node/python/java/rust/dotnet-minimal | #36/30/30/25/24 | PASS | rust-minimal PASS (vs FAIL GitLab -> confirme INFRA-1) |
| node/python/java/rust/dotnet-complete | #90/77/66/64/71 | PASS | node-complete : `business=warning` (container-scan, CVE image de base, preset pragmatic) = attendu |
| error-build / error-test / error-config | #7/11/7 | PASS | echec intentionnel correctement detecte |
| node-deploy | #49 puis **#50** | faux-PASS puis **PASS** | #49 deploy skippe (course param) ; #50 deploy reel via compose (6s) |
| node-plan-tag | #2 | PASS | plan-driven, voie release lancee (`reason=no-diff`) |
| error-deploy | #12 puis **#13** | FAIL puis **PASS** | #12 deploy skippe -> build SUCCESS inattendu ; #13 deploy echoue sur namespace absent = attendu |

Groupes A,C,H : 13/13 PASS. Les 3 scenarios `--only` : tous PASS apres
re-run pour node-deploy et error-deploy (cf. HARN-3).

## 4. Ecarts -- classes avec preuves

### brik-bug

**BUG-1 (HIGH) -- Le planner ignore le contexte release en mode `balanced`.**

`lib/planning/plan.sh:92-113` -- seul `mode=safe` court-circuite le filtre
d'impact. En `balanced`, le filtre per-file s'applique a **toutes** les
etapes (release, build, lint, sast, scan, test, package) **sans consulter
`context`**. Sur un tag (`context=release`) avec un diff non vide et
non-impactant, la voie release est skippee `no-impact`. Le `context` est
calcule mais jamais utilise pour forcer la voie release.

- *GitLab : SE MANIFESTE* -- node-plan-tag FAIL (session precedente),
  release/build/lint/sast/scan/test/package skippes `no-impact`.
- *Jenkins : LATENT* -- node-plan-tag #2 plan.json : toutes les etapes
  `run / reason=no-diff`. Le diff Jenkins `origin/main..HEAD` est vide
  (HEAD = tete de main) -> `plan.decide` court-circuite en `no-diff`
  (run-all) avant d'atteindre le filtre. **Meme code partage** ; le bug est
  dormant uniquement parce que l'adaptateur Jenkins fournit un diff vide.
- Preuve : `lib/planning/plan.sh:92-113` ; plan.json node-plan-tag
  (`context=release, mode=balanced`, voie release en `run/no-diff`).

**BUG-2 (MEDIUM) -- `notify.yml` couple notify au flag deploy.**

`lib/registry/manifests/stages/notify.yml` :
`gate: {mode: opt_in, opt_in_flag: --with-deploy}`. L'etape finale de
notification est gatee derriere `--with-deploy` -> tout plan sans deploy
produit `notify: skip, reason=opt-in-flag-missing`.

- Preuve : plan.json node-plan-tag `notify: skip opt-in-flag-missing`.
- Le wrapper Jenkins **masque la consequence** : `brikPipeline.groovy:424-462`
  lance Notify inconditionnellement (`finally { stage('Notify') }`), sans
  consulter le plan. Le plan.json est donc en contradiction avec le
  comportement reel pour cette etape. Soit le manifest est faux (notify
  devrait etre `mode: blocking`), soit le contrat plan/wrapper est incoherent.

**BUG-3 (LOW) -- plan.json `changes.files` toujours `[]`.**

`lib/planning/plan_writer.sh:100-106` code en dur `files:[]` dans les deux
branches (`source==none` et `source!=none`). L'ensemble reel des fichiers
modifies (utilise en interne pour les decisions d'impact) n'est jamais
serialise. Le bloc `changes` de plan.json est trompeur (ex. node-plan-tag :
`source=local, from_ref=origin/main, to_ref=HEAD, files=[]`).

**BUG-4 (LOW, universel) -- `scripts/compile-registry.sh:163` utilise `shasum`.**

`command not found` sur les images runner Alpine (utiliser `sha256sum`). La
compilation du registry aboutit malgre tout. (Ecart #5 GitLab, s'applique a
tout runner Alpine.)

### infra-lab

**INFRA-1 -- GitLab rust-minimal FAIL** : lock git perime du gitlab-runner
(`could not lock config file .gitlab-runner.ext.conf: File exists`) des
`get_sources`. **Confirme non-brik** : rust-minimal PASS sur Jenkins.

**INFRA-2 -- GitLab dotnet-complete FAIL** : `brik-package` build l'image OK
puis `docker push` vers Nexus echoue
(`proxyconnect tcp: dial tcp 192.168.65.1:3128: i/o timeout` -- buildx route
via un proxy injoignable). brik reporte correctement exit 5. **Confirme
non-brik** : dotnet-complete PASS sur Jenkins.

**INFRA-3 (transitoire, resolu)** -- GitLab en cours de boot au demarrage de
session (puma en redemarrage, runner en 502 Bad Gateway). Auto-resolu, aucune
recreation necessaire. Pas un defaut.

### harness

**HARN-1 (HIGH pour le signal CI) -- `suite.sh:237-239` : `result_dir: unbound variable`.**

`result_dir` est `local` a la fonction de suite mais reference par un
`trap 'rm -rf "$result_dir"' EXIT` qui se declenche **apres** le retour de la
fonction. Sous `set -u`, le trap avorte et le script sort en **exit 1** --
meme sur un run 100% PASS. Affecte les **deux** suites (`suite.sh` partage),
uniquement le chemin batche (`--batch-size > 1`).

- Preuve : groupes A,C,H = 13/13 PASS, "PASSED" affiche, puis
  `result_dir: unbound variable`, `SUITE_EXIT=1`.

**HARN-2 (MEDIUM) -- `error-deploy` mal classe par `_suite_get_group`.**

Le `case` teste `*-deploy*) -> E` **avant** `error-*) -> H`. `error-deploy`
contient `-deploy` -> happe en groupe E. `--groups H` l'exclut silencieusement.
Affecte les deux suites.

- Preuve : run groupes A,C,H = seulement 3 scenarios d'erreur
  (error-build/test/config), error-deploy absent.

**HARN-3 (MEDIUM) -- Course d'enregistrement de parametre Jenkins.**

Quand un nouveau parametre (`BRIK_WITH_DEPLOY`) est ajoute a
`brikPipeline.groovy`, le **premier build** de chaque job deja parametre ne
peut pas le recevoir : le modele de parametres du job n'est mis a jour que par
le `properties([parameters(...)])` de ce build-la, trop tard pour son propre
trigger ; Jenkins drope silencieusement le parametre POSTe inconnu.
`e2e.jenkins.pre_register_params` ne corrige pas (early-return `already-set`
sur les jobs deja parametres).

- Consequence : node-deploy #49 + error-deploy #12 ont perdu
  `BRIK_WITH_DEPLOY=true` -> deploy skippe `opt-in-flag-missing` -> node-deploy
  faux-PASS (Deploy 0s), error-deploy FAIL (build SUCCESS au lieu de FAILURE).
  Re-runs #50/#13 (parametre desormais enregistre par le `properties()` de
  #49/#12) : corrects -- #50 deploie via compose (6s), #13 echoue sur le
  namespace absent comme prevu.
- Preuve : API params #49/#12 = `BRIK_DRY_RUN`+`BRIK_TAG` seulement ;
  #50/#13 deploy tourne.
- *Portee reelle* : ceci touche aussi un vrai utilisateur -- le 1er build
  Jenkins apres une montee de version brik ajoutant un parametre de pipeline
  le dropera. Merite une note de release brik ou un warm-up harness.

**HARN-4 (LOW) -- groupe `I` absent cote Jenkins.**

`_suite_get_group` de `jenkins-suite.sh` n'a pas de cas
`node-plan-*) -> I` (gitlab-suite.sh oui). `--groups I` ne matche rien ;
node-plan-tag/node-plan-invalid doivent passer par `--only`.

**HARN-5 (note) -- "stages[].run = null" n'est pas un bug brik.**

Le champ contractuel de plan.json est `.decision` (run/skip). `.run` n'existe
pas. Tous les vrais consommateurs utilisent `.decision`
(`lib/planning/plan_reader.sh:55`, GitLab `templates/jobs/_plan.yml:49`). Le
sous-ecart GitLab "stages[].run null" est un artefact de l'outil de collecte
de la session precedente, qui interrogeait `.run`.

### mineur / cosmetique

- **MIN-1** -- Warnings NG `recordIssues` (stage Verify) logge
  `[-ERROR-] No files found for pattern 'brik-artifacts/aggregate.sarif'` a
  chaque build : `aggregate.sarif` n'est produit que plus tard par notify.
  Non-fatal (try/catch + fallback per-stage, le commentaire du code l'assume).
  Bruit de log.
- **MIN-2** -- plan.json enumere une decision pour l'etape `promote`, mais le
  flow fixe Jenkins n'a pas de stage Promote (et la liste d'unstash de Notify
  l'omet). Decision produite mais jamais consommee. Low (promote pas encore
  cable dans le flow fixe).
- **MIN-3** -- error-deploy Verify : le step `junit` Jenkins logge
  `No test report files were found` pour node-deploy-failure.
  `allowEmptyResults: true` -> non-fatal. Probablement attendu pour ce fixture.

## 5. Parite GitLab <-> Jenkins (node-plan-tag)

**node-plan-tag sur Jenkins PASSE, en mode plan-driven, et le legacy fallback
n'est PAS implique.** Le planner reussit (`balanced` est un mode valide) : la
console montre `plan written`, aucun message
`planner failed; falling back to legacy flow`. Le repli legacy ne concerne que
**node-plan-invalid** (mode `aggressive` rejete).

node-plan-tag exerce donc bien la voie plan-driven sur les deux plateformes.
La difference GitLab/Jenkins tient uniquement au **contenu du diff** :

- GitLab : diff non vide (vrai range de commits sur le tag) -> filtre
  d'impact actif -> `skip no-impact` -> **bug BUG-1 se manifeste**.
- Jenkins : diff `origin/main..HEAD` vide -> `run no-diff` (run-all
  conservateur) -> **bug BUG-1 dormant**.

Conclusion : **BUG-1 est un bug du planner (brik-lib partage), pas masque par
le legacy fallback**. Il est latent sur Jenkins et se reveillerait des qu'un
build Jenkins aurait un diff non vide et non-impactant sur un tag release.

## 6. Correctifs proposes (aucun applique -- en attente d'arbitrage)

| # | Correctif propose | Fichier |
|---|---|---|
| BUG-1 | En `balanced`, bypasser le filtre d'impact pour la voie release quand `context=release` (ou faire dependre le filtre du contexte) | `brik/lib/planning/plan.sh` |
| BUG-2 | Retirer `opt_in_flag: --with-deploy` de notify, ou passer notify en `mode: blocking` | `brik/lib/registry/manifests/stages/notify.yml` |
| BUG-3 | Serialiser le vrai set de fichiers dans `changes.files` (ou documenter que le champ est volontairement vide) | `brik/lib/planning/plan_writer.sh` |
| BUG-4 | `shasum` -> `sha256sum` | `brik/scripts/compile-registry.sh:163` |
| HARN-1 | Rendre `result_dir` non-local, ou figer la valeur dans le trap (`trap "rm -rf '$result_dir'" EXIT`) | `briklab/scripts/lib/e2e/lib/suite.sh:237` |
| HARN-2 | Mettre `error-*)` avant `*-deploy*)` dans `_suite_get_group` (les 2 suites) | `briklab/scripts/lib/e2e/{gitlab,jenkins}-suite.sh` |
| HARN-3 | `pre_register_params` : reconcilier les parametres manquants sur un job deja parametre, ou build de warm-up | `briklab/scripts/lib/e2e/lib/jenkins-api.sh:106` |
| HARN-4 | Ajouter le cas `node-plan-*) -> I` a `jenkins-suite.sh` | `briklab/scripts/lib/e2e/jenkins-suite.sh` |

Modifications brik non committees preexistantes (`lib/cli/plan.sh` SC2034,
`Makefile`) : **non touchees**, non liees a cette campagne.

## 7. Annexe -- preuves brutes

- node-plan-tag plan.json (workspace Jenkins) : `context=release`,
  `mode=balanced`, `brikVersion=0.6.0`,
  `changes={files:[], from_ref:origin/main, source:local, to_ref:HEAD}`,
  stages init/release/build/lint/sast/scan/test/package/container-scan/promote
  tous `decision=run reason=no-diff`, deploy+notify `decision=skip
  reason=opt-in-flag-missing`.
- node-deploy #49 : `brik plan ... --with-release --with-package` (sans
  `--with-deploy`) ; `[brik plan] deploy: skipped (reason=opt-in-flag-missing)`.
- node-deploy #50 : `[deploy] deploying to staging (target=compose)` ;
  `docker compose -f docker-compose.yml up -d` ;
  `[deploy] compose deployment completed successfully`.
- error-deploy #13 : `kubectl apply ... --namespace brik-nonexistent` ;
  `Error from server (NotFound): namespaces "brik-nonexistent" not found` ;
  `[brik] stage deploy failed with exit code 1`.
- jenkins-suite.sh groupes A,C,H : `Total: 13 | Passed: 13 | Failed: 0`, puis
  `jenkins-suite.sh: line 1: result_dir: unbound variable`, `SUITE_EXIT=1`.
