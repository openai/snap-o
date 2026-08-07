import type { InspectorServerReference, TweakUpdate, TweakUpdateError, TweakValue } from "../../network/bridge-types";
import type { NetworkClient } from "../../network/client";

interface TweakUpdateQueueCallbacks {
  onUpdate(tweaks: TweakUpdate[], pending: ReadonlyMap<string, TweakValue>): void;
  onRejected?(
    errors: TweakUpdateError[],
    pending: ReadonlyMap<string, TweakValue>,
    inFlight: ReadonlySet<string>,
    isCurrent: () => boolean
  ): void;
  onError(error: string | null): void;
  onSavingChange(saving: boolean): void;
}

export class TweakUpdateQueue {
  readonly pending = new Map<string, TweakValue>();
  readonly inFlight = new Set<string>();

  private saving = false;
  private generation = 0;

  constructor(
    private readonly client: Pick<NetworkClient, "updateTweaks">,
    private readonly server: InspectorServerReference,
    private readonly callbacks: TweakUpdateQueueCallbacks
  ) {}

  enqueue(name: string, value: TweakValue): void {
    this.pending.set(name, value);
  }

  cancel(): void {
    this.generation += 1;
    this.pending.clear();
    this.inFlight.clear();
  }

  async flush(): Promise<void> {
    if (this.saving || this.pending.size === 0) return;

    const generation = this.generation;
    const errors: TweakUpdateError[] = [];
    this.saving = true;
    this.callbacks.onSavingChange(true);

    try {
      while (generation === this.generation && this.pending.size > 0) {
        const values = Object.fromEntries(this.pending);
        const names = Object.keys(values);
        this.pending.clear();
        for (const name of names) this.inFlight.add(name);

        let result;
        try {
          result = await this.client.updateTweaks({ server: this.server, values });
        } finally {
          for (const name of names) this.inFlight.delete(name);
        }

        if (generation !== this.generation) return;
        this.callbacks.onUpdate(result.tweaks, this.pending);
        if (result.errors?.length) {
          errors.push(...result.errors);
          this.callbacks.onRejected?.(result.errors, this.pending, this.inFlight, () => generation === this.generation);
        }
      }

      if (generation === this.generation) {
        this.callbacks.onError(errors.length ? errors.map(({ name, error }) => `${name}: ${error}`).join("; ") : null);
      }
    } catch (cause: unknown) {
      if (generation !== this.generation) return;
      this.pending.clear();
      this.callbacks.onError(cause instanceof Error ? cause.message : "Unable to update tweaks.");
    } finally {
      this.saving = false;

      if (generation === this.generation) {
        this.callbacks.onSavingChange(false);
      } else if (this.pending.size > 0) {
        void this.flush();
      }
    }
  }
}
