import Foundation

/// Everyday English words. An official name that is just one of these (a zone or item whose whole
/// name is an ordinary word) would be "found" in almost every chat line, so such names are not
/// matched as plain words. my_terms.tsv and nicknames.tsv are never filtered by this.
enum GlossaryStopwords {
    static func contains(_ key: String) -> Bool {
        everyday.contains(key) || slang.contains(key) || ordinaryNames.contains(key)
    }

    /// Dictionary words only. An abbreviation spelled like one of these ("IF", "NO", "DE") is
    /// honoured only in capitals; chat slang ("lf", "dps", "np") is itself the abbreviation, so
    /// it is not here.
    static func isEverydayWord(_ key: String) -> Bool { everyday.contains(key) || foreign.contains(key) }

    private static func set(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }

    private static let everyday: Set<String> = set("""
        a about above across act add after again against age ago agree ah air all almost alone along already also \
        although always am among an and angry animal another answer any anyone anything are area arm around art as ask \
        at ate away back bad bag ball bank base be bear beat beautiful became because become bed been before began \
        begin behind being believe below best better between big bird bit black blood blue boat body bone book born \
        both bottom box boy break bring broke brother brought brown build burn busy but buy by call came can cant car \
        care carry case cat catch caught cause center chance change check child children city class clean clear close \
        cold color come common cool corner cost could country course cover cross cry cut dark day dead deal dear death \
        deep did didnt die do does doesnt dog doing done dont door down draw dream dress drink drive drop dry during \
        each ear early earth east easy eat edge egg eight either else end enemy enough even evening ever every \
        everyone everything eye face fact fair fall family far farm fast fat father feel feet fell felt few field \
        fight fill final find fine finger finish fire first fish five floor fly follow food foot for force forest \
        forget form found four free fresh friend from front full fun game garden gave get girl give glad glass go god \
        goes going gold gone good got great green grew ground group grow guess guy had hair half hall hand happen \
        happy hard has hat hate have he head hear heard heart heat heavy held hell hello help her here hey hi high \
        hill him his hit hold hole home hope horse hot hour house how however huge human hundred hunt hurt i ice idea \
        if ill im in inside instead into iron is island isnt it its ive job join just keep kept key kill kind king \
        knew know land large last late later laugh law lay lead learn least leave led left leg less let letter level \
        lie life light like line list listen little live long look lord lose lost lot loud love low luck lucky made \
        main make man many map mark matter may maybe me mean meet men might mile mind mine minute miss moment money \
        month moon more morning most mother mountain mouth move much music must my name near need never new next nice \
        night nine no nobody none nope nor north not note nothing now number of off offer often oh oil ok okay old on \
        once one only open or order other our out outside over own page paid pain pair paper part party pass past pay \
        peace people perhaps person pick piece place plan plant play please point poor power press pretty price \
        problem pull push put question quick quiet quite rain ran reach read ready real really reason red rest \
        rich ride right ring rise river road rock room round rule run safe said same sat save saw say school sea \
        second see seem seen self sell send sent set seven several shall shape share she ship shop short should \
        show shut side sign silver simple since sing sir sister sit six size skin sky sleep slow small smile snow so \
        soft some someone something sometimes son song soon sorry sound south space speak special spend spot \
        spring stand star start state stay step still stone stood stop store story straight strange street strong \
        stuff such sudden summer sun sure table take talk tall teach team tell ten test than thank thanks that thats \
        the their them then there these they thing think third this those though thought thousand three through \
        throw tie till time tiny to today together told tomorrow tonight too took top touch toward town trade travel \
        tree tried trip trouble true try turn twenty two under until up upon us use usual very voice wait walk wall \
        want war warm was wash wasnt watch water way we wear weather week well went were west what when where \
        whether which while white who whole whom whose why wide wife wild will win wind window winter wish with \
        within without woman women wonder wont wood word work world worry worse worst would wrong year yellow yes \
        yesterday yet you young your youre yours \
        anyone anybody somebody guys item items damage skill gold silver copper bag bags bank mail \
        invite whisper channel farm farming sell selling buy buying free cheap price deal need needs \
        want wants looking group full last spot more run runs fast quick heal heals \
        id hed shed wed hes shes lets whos whats wheres hows heres theres theyre youd itd yall youll theyll \
        weve youve theyve arent werent couldnt shouldnt wouldnt havent hasnt hadnt aint \
        toss moss loss mass boss bosses devs ads ids diss \
        lower upper living inn seat bug bugs tear leaf flood streets docks ninja tower towers patch \
        darn shat strangle gadget grizzly attack
        """)

    /// The commonest short words of Spanish, Portuguese, French, German and Italian chat, as
    /// keys (accents folded): "grupo de 5", "et toi", "os dois".
    private static let foreign: Set<String> = set("""
        de la el en es se un una uno me te tu su mi si lo le les las los des du et il je ne est da na um uma \
        que con por para sin mas pero muy mais com sem nao ou em ao eu pra der die das und ich ist nicht ein zu mit \
        auf fur von wir sie che non per ma ha ho al del ya hay soy eres esta este eso qui est sont pas pour dans sur
        """)

    /// Ordinary words that are also the whole official name of some zone, instance, boss or
    /// faction ("Midnight", "City", "Beauty"). Unlike `everyday` these do not turn abbreviations
    /// or their other spellings capitals-only.
    private static let ordinaryNames: Set<String> = set("""
        midnight continent garrison labyrinth bastion beauty weaver classic legion glory wonderland downfall \
        landslide glutton mason elevator tower temple market shrine ridge haven prison quarry workshop lighthouse \
        bonfire junction overlook waterfall shipwreck plunge hangar refinery shipyard warship opulence flotsam \
        echelon hydrangea underpin galleon phalanx initial adventurer elsewhen
        """)

    /// Everyday Korean words that are also the whole official name of something: a map list
    /// label, a quest area, a boss title. A chat line that merely says "이 퀘스트에 대해" or
    /// "도시로 갈게요" must not be told that 대해 is The Great Sea.
    static func isEverydayKorean(_ key: String) -> Bool { korean.contains(key) }

    private static let korean: Set<String> = set("""
        대해 도시 임시 없음 시장 정원 광장 감옥 바다 농장 폐허 명예 영혼 길드 대륙 군도 미궁 저편 한밤 심판 \
        옥좌 속성 산사태 석공 수국 울림 괴수 흑기사 도살자 포식자 간수 명사수 시종장 대지주 백작 장군 재상 \
        감시관 방직공 승천자 군단 구덩이 전쟁터 이계 쿠키 마더 똑똑 모험가 입문 아름이 미라 여관 은행 \
        경매장 우체통 마을 항구 다리 동굴 호수 강 숲 산 들판 언덕 해안 해변 사막 평원 계곡 골짜기 고개 \
        탑 성 성채 요새 사원 신전 무덤 묘지 광산 채석장 제재소 목장 과수원 주둔지 야영지 전초기지 \
        감시탑 등대 부두 선착장 조선소 대장간 훈련장 투기장 경기장 도서관 연구실 실험실 창고 지하실 \
        입구 출구 통로 계단 복도 안뜰 마당 정문 성문 관문 왕좌 알현실 회의실 보물 열쇠 상자 가방 \
        공격 방어 사격 발사 휴식 준비 시작 종료 승리 패배 전투 전쟁 평화 희망 절망 분노 공포 고통 \
        치유 회복 보호 복수 징벌 심문 처형 희생 구원 축복 저주 정화 소환 추방 귀환 탈출 추적 정찰 \
        오늘 내일 어제 지금 나중 먼저 다음 이전 처음 마지막 여기 거기 저기 우리 저희 누구 무엇 어디 \
        사람 친구 동료 형제 자매 아이 어른 주인 손님 상인 병사 대장 선장 왕 여왕 왕자 공주 \
        시간 하루 아침 저녁 밤 새벽 정오 자정 봄 여름 가을 겨울 날씨 바람 폭풍 번개 천둥 안개 그림자 \
        이름 질문 대답 부탁 감사 인사 사과 약속 계획 문제 방법 이유 결과 기회 선택 준비물 재료 \
        자리 하나 둘 셋 모두 전부 조금 많이 정말 진짜 그냥 혹시 아마 역시 다시 계속 바로 같이
        """)

    /// Whether a word of a place's name is too ordinary to point at the place by itself: an
    /// everyday word, or one of the words fantasy place names are made of that chat uses all
    /// day for something else ("The Park", "The Green Belt", "Raptor Ridge", "Thieves Camp").
    static func isOrdinaryPlaceWord(_ key: String) -> Bool { contains(key) || placeNames.contains(key) }

    /// Words found in the names of places (zone_places.<flavor>.tsv) that are no clue to a
    /// place when a chat line says them: verbs and adjectives, things players carry, fight or
    /// are (items, creatures, classes), abstract nouns. Nouns for a kind of place (harbor,
    /// site, tavern, ruins) are deliberately not here: "the harbor" said in a zone's own
    /// channel is that zone's harbor.
    private static let placeNames: Set<String> = set("""
        abandoned access advance ages ambush ancient ancients anger approach arcane arms assault authority \
        bait balance band bargain battle beast beasts bears bell belly belt bite bitter blade blades blessed \
        blind block bloody bloom bones boom bound bounty brave breath breathing breeze brew broken bronze \
        bubble bucket buried burned burning buzz cage calm camp camps candle cell central chains challenge \
        champion champions changed chaos chill choice chosen claim clan claw claws cloud club coal command \
        company core corners corrupted courage cracked crash creepy crown crystal cursed cutter dagger damned \
        dancing darkness daughter dawn deaths decay defense demon design destiny destroyed destroyer \
        destruction devils dire distant dive doom double drag dragon dragons drain drake dread dreams drift \
        drunk drunken dust dusty dying eastern echo elder elders elemental elements emerald emperor empire \
        empty endless engine engineers escape eternal exchange exile exit eyes faded faithful fallen falling \
        falls fang fangs fate favor fear feast feather feral fighting filled fishing fist flag flame flames \
        flesh floating flow focus forbidden forever forgotten forsaken forward foul frost frozen fury ghost \
        giant giants gift goblin golden grace grand grasp grave greasy grey grief grim guard guardian \
        guidance hammer handling hanging harvest hearts heroes hidden holding honor hook hopes horn horror \
        howl howling hungry hunter hunters hunting imagination immortal infinite inner invasion keeper \
        keepers kindness kings knowledge labor lady launch lava lazy league legendary legs lift lightning \
        lights lion logging lonely loyalty machine madness mage mages mana march master masters meat melody \
        memories memory merchant military mining mirror misery missing mist mothers murder mysterious needle \
        nightmare northern nowhere oath offensive office officer omen ones opening operations opportunity \
        outer pale panic park parking parting path patience patrol pearl pile pillow pipe pitch plague \
        planes pleasant pleasure plot pocket port portal post pride priest prime prince public punishment \
        purchase purple queen rage raiders rainbow range raptor razor rear rebel records regret relief \
        remains research resting retreat ritual roar rocket rocks roller rolling root roots rose royal ruby \
        ruin ruined rune rusty sacred sailor salty samples sand savage scale scales scar scenario scrap \
        screaming scroll seal sealed secret secrets serpent service setting shadow shadows shaman shallow \
        shell shield shields shifting shining shipping shooting siege silence silent sink sisters skull slam \
        slaughter slave sleeping slick slope smoking society soldiers sons sorrow soul souls southern spark \
        speakers spear spike spine spirit spirits spite spoke spray squeeze stable stars stash steam steel \
        steps stew sting stones storm storms stream strength strike strip study stump suffering suite \
        summoning sunrise sunset supply support surge swarming swift swim sword tail tale tanks taps teeth \
        terror thread throne thunder tide tiger times titan toll tooth torch torment totem toxic traders \
        trading trail training transfer treasure trial trials triumph troll trust truths tunnel turtle \
        twilight twin twisted unit unity used valor vengeance venom venture vice vicious victory vision \
        visions void wagon wake walking ward warrior warriors waste watcher waters waves western whispers \
        whistle wicked wilds winds wing wisdom witch wizard wolf words worlds worm wound wounds wrath wreck \
        yard youth zone \
        cape capital dwarven estate general helm highway pumpkin rotting satyr sundown survey thorn tranquil
        """)

    /// Whether a word of a chat line is too ordinary to be taken for a place's name cut short.
    static func isOrdinaryPiece(_ key: String) -> Bool { pieces.contains(key) }

    /// Ordinary words that happen to begin a longer word of some place's name ("plate" and a
    /// Plateau, "split" and Splithoof, "stage" and a Stagecoach). Found by running an English
    /// word list against both zone_places files; the everyday words above are left out before
    /// this list is asked, and so are words that are a whole word of some place's name.
    private static let pieces: Set<String> = set("""
        actual alter anchor author awake broad craft crush element event extra forbid glitter golem growth \
        hatch honey jewel origin plate prank protect reside resident rough shack shiver skunk solar speed \
        splinter split spore stage stare stock stoned stout sunder swarm thick transform trick undergo \
        wilder wither
        """)

    /// Chat and game slang that is too common to be worth reporting as an official name.
    private static let slang: Set<String> = set("""
        lol lmao rofl omg wtf wth pls plz thx ty np gg gl hf brb afk sry srry yeah yep yup nah hmm haha hehe lf \
        guild raid dungeon quest loot gear mount mob mobs boss healer tank dps buff debuff spell talent spec lvl \
        inv server realm alliance horde pvp pve grind
        """)
}
