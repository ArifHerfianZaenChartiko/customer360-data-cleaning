// Power Query (M) for the "products_clean" query in products_clean.xlsx
// Source: the raw catalog stored in the same workbook as table tbl_raw (sheet raw_products).
// Text and number clean-up happens here; category mapping and price validation are Excel formulas
// added to the output table (see the notes sheet in the workbook).
let
    Source = Excel.CurrentWorkbook(){[Name = "tbl_raw"]}[Content],
    AsText = Table.TransformColumnTypes(Source, {
        {"product_id", type text}, {"product_name", type text}, {"category", type text}, {"price", type text}
    }),
    NullToEmpty = Table.ReplaceValue(AsText, null, "", Replacer.ReplaceValue, {"product_id", "product_name", "category", "price"}),
    Trimmed = Table.TransformColumns(NullToEmpty, {
        {"product_id", Text.Trim, type text}, {"product_name", Text.Trim, type text},
        {"category", Text.Trim, type text}, {"price", Text.Trim, type text}
    }),

    // product_name: remove digits and symbols, split joined words (UsuallyHear -> Usually Hear),
    // fix the doubled 'aa' typo (Beaautiful -> Beautiful), then proper case
    NoNoise = Table.TransformColumns(Trimmed, {{"product_name", each Text.Select(_, {"A".."Z", "a".."z", " "}), type text}}),
    SplitJoined = Table.TransformColumns(NoNoise, {{"product_name",
        each Text.Combine(Splitter.SplitTextByCharacterTransition({"a".."z"}, {"A".."Z"})(_), " "), type text}}),
    FixDoubledA = Table.TransformColumns(SplitJoined, {{"product_name", each Text.Replace(Text.Replace(_, "aa", "a"), "AA", "A"), type text}}),
    ProperCase = Table.TransformColumns(FixDoubledA, {{"product_name", each Text.Proper(Text.Trim(_)), type text}}),

    // category_key: lower case, leetspeak '3' -> 'e', trailing '_' or '-' removed.
    // The key is mapped to one of 8 standard categories by XLOOKUP on tbl_category_map.
    CategoryKey = Table.AddColumn(ProperCase, "category_key",
        each Text.TrimEnd(Text.Replace(Text.Lower([category]), "3", "e"), {"_", "-"}), type text),

    // price: text -> number ('1,200' -> 1200); 'NaN' and other text become null.
    // Whether the number is a valid price is decided by the price_status formula.
    PriceNumber = Table.AddColumn(CategoryKey, "price_number", each
        let n = try Number.FromText([price], "en-US") otherwise null
        in if n = null or Number.IsNaN(n) then null else n, type nullable number),

    Renamed = Table.RenameColumns(PriceNumber, {{"price", "price_raw"}}),
    Result = Table.SelectColumns(Renamed, {"product_id", "product_name", "category_key", "price_raw", "price_number"})
in
    Result
