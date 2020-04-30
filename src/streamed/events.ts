import { Contract, EventData } from "web3-eth-contract"
import { ContractEvent } from "../../build/types/types"

/**
 * Event type specified by name.
 */
type Event<
  C extends Contract,
  T extends Exclude<keyof C["events"], "allEvents">,
> = EventMetadata & EventDiscriminant<C, T>

/**
 * Concrete event type with known properties based on the event name.
 *
 * @remarks
 * This type definition allows the TypeScript compiler to determine the type of
 * the `returnValues` property based on `event` property checks. For example:
 * ```
 * const eventData: AnyEvent<BatchExchange> // = ...
 * switch (eventData.event) {
 * case "TokenListing":
 *   x.returnValues.token = "..." // OK
 *   break
 * case "Withdraw":
 *   x.returnValues.buyToken = "asdf" // Error: 2339: Property 'buyToken' does not exist on type
 *                                    // '{ user: string; token: string; amount: string; 0: string; 1: string; 2: string; }'.
 *   break
 * }
 * ```
 */
type AnyEvent<C extends Contract> = EventMetadata & EventDiscriminant<C, Exclude<keyof C["events"], "allEvents">>

type EventMetadata = Omit<EventData, "event" | "returnValues">
type EventValues<T> = T extends ContractEvent<infer U> ? U : never
type EventDiscriminant<
  C extends Contract,
  T extends Exclude<keyof C["events"], "allEvents">,
> = T extends any ? {
  event: T,
  returnValues: EventValues<C["events"][T]>,
} : never
