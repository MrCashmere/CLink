export class QuickShareTxtRecordParser {
  parse(records: string[]): Map<string, string> {
    const result = new Map<string, string>();
    records.forEach((record: string): void => {
      const separator = record.indexOf('=');
      if (separator > 0) { result.set(record.substring(0, separator), record.substring(separator + 1)); }
    });
    return result;
  }
}
