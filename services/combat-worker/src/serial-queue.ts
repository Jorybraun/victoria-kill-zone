/** Serializes short room state commits without blocking unrelated input events. */
export class QueueFullError extends Error {}

export class SerialQueue {
  private tail: Promise<void> = Promise.resolve();
  private size = 0;

  run<T>(task: () => Promise<T> | T): Promise<T> {
    if (this.size >= 64) return Promise.reject(new QueueFullError("Room queue full"));
    this.size += 1;
    const result = this.tail.then(task);
    this.tail = result.then(() => { this.size -= 1; }, () => { this.size -= 1; });
    return result;
  }
}
