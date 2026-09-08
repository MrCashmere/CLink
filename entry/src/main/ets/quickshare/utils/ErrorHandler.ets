export class QuickShareErrorHandler {
  message(error: Error | undefined): string {
    return error === undefined ? 'Unknown Quick Share error' : error.message;
  }
}
