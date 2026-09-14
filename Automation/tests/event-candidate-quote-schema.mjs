import fs from "node:fs";

const schemaPath = process.argv[2];
if (!schemaPath) {
  throw new Error("usage: node event-candidate-quote-schema.mjs <schema-path>");
}

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
const quoteSchema = schema.properties.mood.properties.quote;
const pattern = new RegExp(quoteSchema.pattern, "u");
const feff = String.fromCodePoint(0xFEFF);
const acceptedFEFFWireValues = [
  JSON.parse(`"${feff}旅旅旅"`),
  JSON.parse(`"旅旅旅${feff}"`),
  JSON.parse('"\\uFEFF旅旅旅"'),
  JSON.parse('"旅旅旅\\uFEFF"'),
];
const overlongFEFFWireValues = [
  JSON.parse(`"${feff}${"旅".repeat(32)}"`),
  JSON.parse(`"${"旅".repeat(32)}${feff}"`),
  JSON.parse(`"\\uFEFF${"旅".repeat(32)}"`),
  JSON.parse(`"${"旅".repeat(32)}\\uFEFF"`),
];

function validatesDraftStringKeywords(value) {
  if (typeof value !== "string") {
    return false;
  }
  const scalarCount = [...value].length;
  return scalarCount >= quoteSchema.minLength
    && scalarCount <= quoteSchema.maxLength
    && pattern.test(value);
}

const accepted = [
  "潮声方向",
  "\u0085潮声方向",
  "潮声方向\u0085",
  "\u200B潮声方向",
  "潮声方向\u200B",
  "\uFEFF潮声方向",
  "潮声方向\uFEFF",
  ...acceptedFEFFWireValues,
];
const rejected = [
  "\t潮声方向",
  "潮声方向\t",
  " 潮声方向",
  "潮声方向 ",
  "\n潮声方向",
  "潮声方向\n",
  "\r潮声方向",
  "潮声方向\r",
  "潮声\r\n方向",
  "潮声向",
  "旅".repeat(33),
  ...overlongFEFFWireValues,
];

for (const value of accepted) {
  if (!validatesDraftStringKeywords(value)) {
    throw new Error(`schema rejected accepted scalar matrix entry: ${JSON.stringify(value)}`);
  }
}
for (const value of rejected) {
  if (validatesDraftStringKeywords(value)) {
    throw new Error(`schema accepted rejected scalar matrix entry: ${JSON.stringify(value)}`);
  }
}

process.stdout.write("event candidate quote schema verified\n");
