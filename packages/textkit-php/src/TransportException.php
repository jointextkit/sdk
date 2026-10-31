<?php

declare(strict_types=1);

namespace TextKit;

/** Thrown by a Transport when no answer arrived. The client retries it. */
class TransportException extends \RuntimeException
{
    public function __construct(string $message, public readonly bool $timedOut = false, ?\Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
    }
}
